#!/usr/bin/env ruby
# frozen_string_literal: true

# Build-time fetcher for _data/external_articles.yml.
#
# For each entry, downloads the page and fills in title / image / excerpt /
# source from its Open Graph (with Twitter-card and HTML fallbacks) metadata,
# then writes the enriched data back to the YAML file. This runs locally before
# committing -- GitHub Pages builds in safe mode and cannot fetch at build time.
#
# Uses only the Ruby standard library (no native gems) so it runs anywhere with
# a plain `ruby`. Open Graph / Twitter metadata lives in simple <meta> tags,
# which are reliably extracted without a full HTML parser.
#
# Usage:
#   bundle exec rake fetch_articles            # fill only un-fetched entries
#   bundle exec rake fetch_articles -- --force # re-fetch every entry
#   ruby scripts/fetch_articles.rb [--force]   # (equivalent, no bundler needed)
#
# Rules:
#   * Manual values are never overwritten -- only blank fields get filled.
#   * Entries marked `fetched: true` are skipped unless --force is passed
#     (keeps re-runs idempotent and avoids re-hitting sources).
#   * Network failures log a warning and leave the entry renderable.

require "yaml"
require "uri"
require "net/http"
require "cgi"
require "date"

DATA_FILE = File.expand_path("../_data/external_articles.yml", __dir__)
USER_AGENT = "Mozilla/5.0 (compatible; prashantparashar.com article fetcher)"
MAX_REDIRECTS = 5
TIMEOUT = 15

force = ARGV.include?("--force")

# Download a URL, following redirects, returning the response body (or nil).
def fetch_html(url, redirects_left = MAX_REDIRECTS)
  uri = URI.parse(url)
  return nil unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)

  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = (uri.scheme == "https")
  http.open_timeout = TIMEOUT
  http.read_timeout = TIMEOUT

  request = Net::HTTP::Get.new(uri.request_uri)
  request["User-Agent"] = USER_AGENT
  request["Accept"] = "text/html,application/xhtml+xml"

  response = http.request(request)

  case response
  when Net::HTTPSuccess
    # Net::HTTP hands back ASCII-8BIT bytes; treat as UTF-8 and drop invalid
    # sequences so extracted strings serialize as clean YAML (not !binary).
    response.body.to_s.dup.force_encoding("UTF-8").scrub
  when Net::HTTPRedirection
    return nil if redirects_left <= 0

    location = response["location"]
    location = URI.join(url, location).to_s unless location =~ %r{\Ahttps?://}
    fetch_html(location, redirects_left - 1)
  else
    warn "  ! HTTP #{response.code} for #{url}"
    nil
  end
rescue StandardError => e
  warn "  ! fetch failed for #{url}: #{e.class}: #{e.message}"
  nil
end

# Parse every <meta> tag into a lookup of (property|name) => content, regardless
# of attribute order. Returns a hash keyed by the lowercased property/name.
def parse_meta_tags(html)
  meta = {}
  html.scan(/<meta\b[^>]*?>/im).each do |tag|
    # Match the value up to the SAME quote it opened with (via backreference),
    # so an apostrophe inside a double-quoted attribute (e.g. content="India's ...")
    # doesn't truncate the value.
    key = tag[/\b(?:property|name)\s*=\s*(["'])(.*?)\1/im, 2]
    content = tag[/\bcontent\s*=\s*(["'])(.*?)\1/im, 2]
    next unless key && content

    key = key.downcase.strip
    meta[key] ||= CGI.unescapeHTML(content).strip
  end
  meta
end

def first_present(*values)
  values.map { |v| v.to_s.strip }.find { |v| !v.empty? }
end

# Normalize anything date-ish (ISO timestamp, "May 1, 2023", etc.) to YYYY-MM-DD.
def normalize_date(value)
  return nil if value.nil? || value.to_s.strip.empty?

  Date.parse(value.to_s).strftime("%Y-%m-%d")
rescue ArgumentError
  # Fall back to a leading ISO date if Date.parse can't handle the string.
  iso = value.to_s[/\d{4}-\d{2}-\d{2}/]
  iso
end

# Pull a publish/upload date from meta tags, JSON-LD, or microdata.
def extract_date(html, meta)
  candidates = [
    meta["article:published_time"],
    meta["article:modified_time"],
    meta["og:updated_time"],
    meta["datepublished"],
    meta["date"],
    meta["pubdate"],
    meta["publish-date"],
    html[/"(?:datePublished|uploadDate)"\s*:\s*"([^"]+)"/, 1],
    html[/<meta[^>]*itemprop=["'](?:datePublished|uploadDate)["'][^>]*content=["']([^"']+)["']/i, 1],
    html[/<meta[^>]*content=["']([^"']+)["'][^>]*itemprop=["'](?:datePublished|uploadDate)["']/i, 1]
  ]
  candidates.each do |c|
    normalized = normalize_date(c)
    return normalized if normalized
  end
  nil
end

def extract_metadata(html, page_url)
  meta = parse_meta_tags(html)

  page_title = html[%r{<title[^>]*>(.*?)</title>}im, 1]
  page_title = CGI.unescapeHTML(page_title.strip) if page_title

  title = first_present(meta["og:title"], meta["twitter:title"], page_title)

  image = first_present(meta["og:image"], meta["twitter:image"], meta["twitter:image:src"])
  image = URI.join(page_url, image).to_s if image && image !~ %r{\Ahttps?://}

  excerpt = first_present(meta["og:description"], meta["twitter:description"], meta["description"])

  source = first_present(meta["og:site_name"]) || URI.parse(page_url).host&.sub(/\Awww\./, "")

  date = extract_date(html, meta)

  { "title" => title, "image" => image, "excerpt" => excerpt, "source" => source, "date" => date }
end

# --- Load -------------------------------------------------------------------

abort "Data file not found: #{DATA_FILE}" unless File.exist?(DATA_FILE)

raw = File.read(DATA_FILE)
# Preserve the leading comment/instruction block when we rewrite the file.
header_lines = raw.lines.take_while { |line| line.strip.empty? || line.lstrip.start_with?("#") }
header = header_lines.join

entries = YAML.safe_load(raw, permitted_classes: [Date]) || []
abort "Expected #{DATA_FILE} to contain a YAML list of entries." unless entries.is_a?(Array)

if entries.empty?
  puts "No entries in #{File.basename(DATA_FILE)} -- nothing to fetch."
  exit 0
end

# --- Enrich -----------------------------------------------------------------

changed = false

entries.each_with_index do |entry, index|
  url = entry["url"]
  if url.nil? || url.to_s.strip.empty?
    warn "  ! entry ##{index + 1} has no url -- skipping"
    next
  end

  if entry["fetched"] && !force
    puts "= #{url} (already fetched, skipping)"
    next
  end

  puts "> fetching #{url}"
  html = fetch_html(url)

  if html
    extract_metadata(html, url).each do |key, value|
      next if value.nil? || value.to_s.strip.empty?
      # Never clobber a manually-set value.
      if entry[key].nil? || entry[key].to_s.strip.empty?
        entry[key] = value
        changed = true
      end
    end
  end

  # Mark as processed so future runs are idempotent (re-run with --force to redo).
  unless entry["fetched"]
    entry["fetched"] = true
    changed = true
  end
end

# --- Sort (reverse chronological: newest first) -----------------------------

# Stable sort by date descending; entries without a usable date sink to the end.
# `sort_date` (optional, manual) overrides `date` for ordering only -- use it to
# pin an entry to a position without changing the date shown on its card.
ordered = entries.each_with_index.sort_by do |entry, index|
  date = (entry["sort_date"] || entry["date"]).to_s.strip
  sort_key =
    begin
      date.empty? ? -Float::INFINITY : Date.parse(date).to_time.to_i
    rescue ArgumentError
      -Float::INFINITY
    end
  [-sort_key, index]
end.map(&:first)

if ordered != entries
  entries = ordered
  changed = true
end

# --- Write ------------------------------------------------------------------

unless changed
  puts "Nothing changed."
  exit 0
end

body = YAML.dump(entries).sub(/\A---\n/, "")
File.write(DATA_FILE, "#{header}\n#{body}")
puts "Updated #{File.basename(DATA_FILE)}."

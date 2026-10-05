# frozen_string_literal: true

require "download_strategy"
require "utils/github"

# Fetches a GitHub Release asset from a private repository.
# Needs HOMEBREW_GITHUB_API_TOKEN with read access to that repo's releases.
#
# Expected URL:
#   https://github.com/<owner>/<repo>/releases/download/<tag>/<filename>
class GitHubPrivateReleaseDownloadStrategy < CurlDownloadStrategy
  def initialize(url, name, version, **meta)
    super
    parse_url_pattern
    set_github_token
  end

  def parse_url_pattern
    url_pattern = %r{https://github.com/([^/]+)/([^/]+)/releases/download/([^/]+)/(\S+)}
    unless (match = @url.match(url_pattern))
      raise CurlDownloadStrategyError, "Invalid URL for GitHub Release: #{@url}"
    end

    _, @owner, @repo, @tag, @filename = *match
  end

  def download_url
    "https://api.github.com/repos/#{@owner}/#{@repo}/releases/assets/#{asset_id}"
  end

  private

  def _fetch(url:, resolved_url:, timeout:)
    # GitHub serves JSON metadata unless Accept is application/octet-stream.
    curl_download download_url,
                  "--header", "Authorization: Bearer #{@github_token}",
                  "--header", "Accept: application/octet-stream",
                  "--header", "X-GitHub-Api-Version: 2022-11-28",
                  to: temporary_path,
                  timeout: timeout
  end

  def asset_id
    @asset_id ||= resolve_asset_id
  end

  def resolve_asset_id
    release_metadata = GitHub.get_release(@owner, @repo, @tag)
    assets = Array(release_metadata["assets"]).select { |asset| asset["name"] == @filename }
    raise CurlDownloadStrategyError, "Asset not found: #{@filename}" if assets.empty?

    assets.fetch(0).fetch("id")
  end

  def set_github_token
    @github_token = ENV["HOMEBREW_GITHUB_API_TOKEN"].to_s
    if @github_token.empty? && defined?(Homebrew::EnvConfig) &&
       Homebrew::EnvConfig.respond_to?(:github_api_token)
      @github_token = Homebrew::EnvConfig.github_api_token.to_s
    end
    return unless @github_token.empty?

    raise CurlDownloadStrategyError,
          "HOMEBREW_GITHUB_API_TOKEN is required to download this private cask."
  end
end

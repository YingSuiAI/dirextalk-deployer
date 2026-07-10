package updater

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
)

const (
	GitHubLatestReleaseAPI = "https://api.github.com/repos/YingSuiAI/dirextalk-message-server/releases/latest"
	manifestAssetName      = "release-manifest.json"
	checksumAssetName      = "release-manifest.json.sha256"
	maxReleaseMetadataSize = 1024 * 1024
	maxReleaseAssetSize    = 1024 * 1024
)

var checksumPattern = regexp.MustCompile(`^([0-9a-f]{64})  release-manifest\.json\n?$`)

type ResolvedRelease struct {
	Source         string `json:"source"`
	Version        string `json:"version"`
	Image          string `json:"image"`
	Digest         string `json:"digest"`
	ImageRef       string `json:"image_ref"`
	ManifestDigest string `json:"manifest_digest"`
	manifestData   []byte
}

type GitHubReleaseSource struct {
	client *http.Client
}

func NewGitHubReleaseSource(client *http.Client) *GitHubReleaseSource {
	if client == nil {
		client = http.DefaultClient
	}
	return &GitHubReleaseSource{client: client}
}

func (source *GitHubReleaseSource) Latest(ctx context.Context) ([]byte, error) {
	resolved, err := source.Resolve(ctx)
	if err != nil {
		return nil, err
	}
	return append([]byte(nil), resolved.manifestData...), nil
}

func (source *GitHubReleaseSource) Resolve(ctx context.Context) (ResolvedRelease, error) {
	metadataData, err := source.get(ctx, GitHubLatestReleaseAPI, maxReleaseMetadataSize)
	if err != nil {
		return ResolvedRelease{}, fmt.Errorf("fetch latest formal release: %w", err)
	}
	var metadata struct {
		TagName    string `json:"tag_name"`
		Draft      bool   `json:"draft"`
		Prerelease bool   `json:"prerelease"`
		Assets     []struct {
			Name string `json:"name"`
			URL  string `json:"browser_download_url"`
		} `json:"assets"`
	}
	decoder := json.NewDecoder(bytes.NewReader(metadataData))
	if err := decoder.Decode(&metadata); err != nil {
		return ResolvedRelease{}, fmt.Errorf("decode latest formal release metadata: %w", err)
	}
	if err := ensureJSONEOF(decoder, "latest formal release metadata"); err != nil {
		return ResolvedRelease{}, err
	}
	if metadata.Draft || metadata.Prerelease {
		return ResolvedRelease{}, fmt.Errorf("latest release is not a published stable release")
	}
	if _, err := parseCanonicalVersion("release tag", metadata.TagName); err != nil {
		return ResolvedRelease{}, err
	}
	assetURLs := map[string]string{}
	for _, asset := range metadata.Assets {
		if asset.Name != manifestAssetName && asset.Name != checksumAssetName {
			continue
		}
		if assetURLs[asset.Name] != "" {
			return ResolvedRelease{}, fmt.Errorf("release contains duplicate %s assets", asset.Name)
		}
		if err := validateReleaseAssetURL(asset.URL, metadata.TagName, asset.Name); err != nil {
			return ResolvedRelease{}, err
		}
		assetURLs[asset.Name] = asset.URL
	}
	manifestURL := assetURLs[manifestAssetName]
	checksumURL := assetURLs[checksumAssetName]
	if manifestURL == "" || checksumURL == "" {
		return ResolvedRelease{}, fmt.Errorf("formal release requires %s and %s assets", manifestAssetName, checksumAssetName)
	}
	manifestData, err := source.get(ctx, manifestURL, maxReleaseAssetSize)
	if err != nil {
		return ResolvedRelease{}, fmt.Errorf("fetch release manifest: %w", err)
	}
	checksumData, err := source.get(ctx, checksumURL, maxReleaseAssetSize)
	if err != nil {
		return ResolvedRelease{}, fmt.Errorf("fetch release manifest checksum: %w", err)
	}
	checksumMatch := checksumPattern.FindStringSubmatch(string(checksumData))
	if checksumMatch == nil {
		return ResolvedRelease{}, fmt.Errorf("release manifest checksum has invalid format")
	}
	manifestHash := sha256.Sum256(manifestData)
	manifestHashHex := hex.EncodeToString(manifestHash[:])
	if checksumMatch[1] != manifestHashHex {
		return ResolvedRelease{}, fmt.Errorf("release manifest checksum mismatch")
	}
	manifest, err := ValidateManifest(manifestData)
	if err != nil {
		return ResolvedRelease{}, err
	}
	if manifest.Version != metadata.TagName {
		return ResolvedRelease{}, fmt.Errorf("release tag %s does not match manifest version %s", metadata.TagName, manifest.Version)
	}
	return ResolvedRelease{
		Source:         "github_release",
		Version:        manifest.Version,
		Image:          manifest.Image,
		Digest:         manifest.ImageDigest,
		ImageRef:       manifest.Image + "@" + manifest.ImageDigest,
		ManifestDigest: "sha256:" + manifestHashHex,
		manifestData:   append([]byte(nil), manifestData...),
	}, nil
}

func (source *GitHubReleaseSource) get(ctx context.Context, requestURL string, maximum int64) ([]byte, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, requestURL, nil)
	if err != nil {
		return nil, err
	}
	request.Header.Set("Accept", "application/vnd.github+json")
	request.Header.Set("User-Agent", "dirextalk-updater")
	response, err := source.client.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("unexpected HTTP status %d", response.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, maximum+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > maximum {
		return nil, fmt.Errorf("response exceeds %d bytes", maximum)
	}
	return data, nil
}

func validateReleaseAssetURL(rawURL, tag, name string) error {
	parsed, err := url.Parse(rawURL)
	if err != nil || parsed.Scheme != "https" || parsed.Host != "github.com" || parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" {
		return fmt.Errorf("release asset %s must use an HTTPS github.com URL", name)
	}
	wantPath := "/YingSuiAI/dirextalk-message-server/releases/download/" + tag + "/" + name
	if parsed.EscapedPath() != wantPath || strings.Contains(parsed.Path, "..") {
		return fmt.Errorf("release asset %s URL does not match release tag", name)
	}
	return nil
}

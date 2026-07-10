package updater

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"strings"
	"testing"
)

const (
	testManifestURL = "https://github.com/YingSuiAI/dirextalk-message-server/releases/download/v1.1.0/release-manifest.json"
	testChecksumURL = "https://github.com/YingSuiAI/dirextalk-message-server/releases/download/v1.1.0/release-manifest.json.sha256"
)

type staticReleaseTransport struct {
	responses map[string]staticHTTPResponse
}

type staticHTTPResponse struct {
	status int
	body   string
}

func (transport staticReleaseTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	response, ok := transport.responses[request.URL.String()]
	if !ok {
		return nil, fmt.Errorf("unexpected request: %s", request.URL)
	}
	return &http.Response{
		StatusCode: response.status,
		Status:     fmt.Sprintf("%d test", response.status),
		Body:       io.NopCloser(strings.NewReader(response.body)),
		Header:     make(http.Header),
		Request:    request,
	}, nil
}

func TestGitHubReleaseSourceResolvesFormalReleaseToImmutableImage(t *testing.T) {
	manifest := validManifestJSON()
	resolved, err := NewGitHubReleaseSource(releaseHTTPClient(manifest, formalReleaseJSON("v1.1.0", false, false), "")).Resolve(context.Background())
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if resolved.Version != "v1.1.0" || resolved.Image != "dirextalk/message-server:v1.1.0" {
		t.Fatalf("unexpected release identity: %#v", resolved)
	}
	if resolved.Digest != "sha256:"+strings.Repeat("a", 64) {
		t.Fatalf("unexpected image digest: %#v", resolved)
	}
	if resolved.ImageRef != resolved.Image+"@"+resolved.Digest {
		t.Fatalf("release is not pinned by digest: %#v", resolved)
	}
	wantManifestDigest := sha256.Sum256([]byte(manifest))
	if resolved.ManifestDigest != "sha256:"+hex.EncodeToString(wantManifestDigest[:]) {
		t.Fatalf("manifest digest mismatch: %#v", resolved)
	}
}

func TestGitHubReleaseSourceRejectsUntrustedOrInconsistentRelease(t *testing.T) {
	tests := []struct {
		name         string
		release      string
		manifest     string
		checksumBody string
	}{
		{name: "draft", release: formalReleaseJSON("v1.1.0", true, false), manifest: validManifestJSON()},
		{name: "prerelease", release: formalReleaseJSON("v1.1.0", false, true), manifest: validManifestJSON()},
		{name: "non canonical tag", release: formalReleaseJSON("latest", false, false), manifest: validManifestJSON()},
		{name: "tag manifest mismatch", release: formalReleaseJSON("v1.2.0", false, false), manifest: validManifestJSON()},
		{name: "image tag mismatch", release: formalReleaseJSON("v1.1.0", false, false), manifest: strings.Replace(validManifestJSON(), "dirextalk/message-server:v1.1.0", "dirextalk/message-server:v9.9.9", 1)},
		{name: "invalid image digest", release: formalReleaseJSON("v1.1.0", false, false), manifest: strings.Replace(validManifestJSON(), "sha256:"+strings.Repeat("a", 64), "sha256:"+strings.Repeat("A", 64), 1)},
		{name: "checksum mismatch", release: formalReleaseJSON("v1.1.0", false, false), manifest: validManifestJSON(), checksumBody: strings.Repeat("0", 64) + "  release-manifest.json\n"},
		{name: "missing assets", release: `{"tag_name":"v1.1.0","draft":false,"prerelease":false,"assets":[]}`, manifest: validManifestJSON()},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			_, err := NewGitHubReleaseSource(releaseHTTPClient(test.manifest, test.release, test.checksumBody)).Resolve(context.Background())
			if err == nil {
				t.Fatal("expected release to be rejected")
			}
		})
	}
}

func TestGitHubReleaseSourceRejectsUnavailableRelease(t *testing.T) {
	client := &http.Client{Transport: staticReleaseTransport{responses: map[string]staticHTTPResponse{
		GitHubLatestReleaseAPI: {status: http.StatusNotFound, body: `{"message":"Not Found"}`},
	}}}
	if _, err := NewGitHubReleaseSource(client).Resolve(context.Background()); err == nil {
		t.Fatal("expected unavailable GitHub Release to fail closed")
	}
}

func releaseHTTPClient(manifest, release, checksumBody string) *http.Client {
	if checksumBody == "" {
		digest := sha256.Sum256([]byte(manifest))
		checksumBody = hex.EncodeToString(digest[:]) + "  release-manifest.json\n"
	}
	return &http.Client{Transport: staticReleaseTransport{responses: map[string]staticHTTPResponse{
		GitHubLatestReleaseAPI: {status: http.StatusOK, body: release},
		testManifestURL:        {status: http.StatusOK, body: manifest},
		testChecksumURL:        {status: http.StatusOK, body: checksumBody},
	}}}
}

func formalReleaseJSON(tag string, draft, prerelease bool) string {
	return fmt.Sprintf(`{
		"tag_name": %q,
		"draft": %t,
		"prerelease": %t,
		"assets": [
			{"name":"release-manifest.json","browser_download_url":%q},
			{"name":"release-manifest.json.sha256","browser_download_url":%q}
		]
	}`, tag, draft, prerelease, testManifestURL, testChecksumURL)
}

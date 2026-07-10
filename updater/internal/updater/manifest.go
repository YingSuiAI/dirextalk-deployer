package updater

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net/url"
	"regexp"
	"strings"

	"github.com/Masterminds/semver/v3"
)

const SupportedManifestVersion = 1

var (
	canonicalVersionPattern = regexp.MustCompile(`^v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$`)
	digestPattern           = regexp.MustCompile(`^sha256:[0-9a-f]{64}$`)
)

type Manifest struct {
	ManifestVersion               int      `json:"manifest_version"`
	Version                       string   `json:"version"`
	Image                         string   `json:"image"`
	ImageDigest                   string   `json:"image_digest"`
	UpgradeFrom                   []string `json:"upgrade_from"`
	SchemaVersion                 int      `json:"schema_version"`
	SchemaCompatVersion           int      `json:"schema_compat_version"`
	MinimumClientVersion          string   `json:"minimum_client_version"`
	MaximumClientVersionExclusive string   `json:"maximum_client_version_exclusive"`
	BackupRequired                bool     `json:"backup_required"`
	RollbackSupported             bool     `json:"rollback_supported"`
	RollbackMode                  string   `json:"rollback_mode"`
	ReleaseNotesURL               string   `json:"release_notes_url"`
}

func ValidateManifest(data []byte) (Manifest, error) {
	var manifest Manifest
	if err := decodeStrict(data, &manifest, "release manifest"); err != nil {
		return Manifest{}, err
	}
	if err := manifest.Validate(); err != nil {
		return Manifest{}, err
	}
	return manifest, nil
}

func (manifest Manifest) Validate() error {
	if manifest.ManifestVersion != SupportedManifestVersion {
		return fmt.Errorf("manifest_version %d is not supported", manifest.ManifestVersion)
	}
	target, err := parseCanonicalVersion("version", manifest.Version)
	if err != nil {
		return err
	}
	if manifest.Image != AllowedImageRepository+":"+manifest.Version {
		return fmt.Errorf("image must be %s tagged with manifest version %s", AllowedImageRepository, manifest.Version)
	}
	if !digestPattern.MatchString(manifest.ImageDigest) {
		return fmt.Errorf("image_digest must be a lowercase sha256 digest")
	}
	for index, value := range manifest.UpgradeFrom {
		constraint, err := semver.NewConstraint(strings.TrimSpace(value))
		if err != nil {
			return fmt.Errorf("upgrade_from[%d] is invalid: %w", index, err)
		}
		if constraint.Check(target) {
			return fmt.Errorf("upgrade_from[%d] must not include target version %s", index, manifest.Version)
		}
	}
	if manifest.SchemaVersion < 1 || manifest.SchemaCompatVersion < 1 || manifest.SchemaCompatVersion > manifest.SchemaVersion {
		return fmt.Errorf("schema versions are invalid")
	}
	minimum, err := parseCanonicalVersion("minimum_client_version", manifest.MinimumClientVersion)
	if err != nil {
		return err
	}
	maximum, err := parseCanonicalVersion("maximum_client_version_exclusive", manifest.MaximumClientVersionExclusive)
	if err != nil {
		return err
	}
	if !minimum.LessThan(maximum) {
		return fmt.Errorf("minimum_client_version must be lower than maximum_client_version_exclusive")
	}
	if !manifest.BackupRequired {
		return fmt.Errorf("backup_required must be true")
	}
	if manifest.RollbackSupported && manifest.RollbackMode != "restore_backup" {
		return fmt.Errorf("rollback_mode must be restore_backup when rollback is supported")
	}
	if !manifest.RollbackSupported && manifest.RollbackMode != "" {
		return fmt.Errorf("rollback_mode must be empty when rollback is not supported")
	}
	parsedURL, err := url.Parse(manifest.ReleaseNotesURL)
	if err != nil || parsedURL.Scheme != "https" || parsedURL.Host != "github.com" || parsedURL.User != nil || parsedURL.RawQuery != "" || parsedURL.Fragment != "" {
		return fmt.Errorf("release_notes_url must be an HTTPS github.com release URL")
	}
	expectedSuffix := "/YingSuiAI/dirextalk-message-server/releases/tag/" + manifest.Version
	if parsedURL.EscapedPath() != expectedSuffix {
		return fmt.Errorf("release_notes_url must identify the manifest release")
	}
	return nil
}

func (manifest Manifest) ValidateUpgradeFrom(currentVersion string) error {
	current, err := parseCanonicalVersion("current_version", currentVersion)
	if err != nil {
		return err
	}
	for _, value := range manifest.UpgradeFrom {
		constraint, constraintErr := semver.NewConstraint(strings.TrimSpace(value))
		if constraintErr != nil {
			return fmt.Errorf("upgrade_from is invalid: %w", constraintErr)
		}
		if constraint.Check(current) {
			return nil
		}
	}
	return fmt.Errorf("current_version %s is not an allowed upgrade source", currentVersion)
}

func parseCanonicalVersion(field, value string) (*semver.Version, error) {
	if !canonicalVersionPattern.MatchString(value) {
		return nil, fmt.Errorf("%s must be a canonical stable version such as v1.0.0", field)
	}
	parsed, err := semver.NewVersion(value)
	if err != nil {
		return nil, fmt.Errorf("%s is invalid: %w", field, err)
	}
	return parsed, nil
}

func manifestDigest(data []byte) string {
	digest := sha256.Sum256(data)
	return "sha256:" + hex.EncodeToString(digest[:])
}

package updater

import (
	"strings"
	"testing"
)

func validManifestJSON() string {
	return `{
		"manifest_version": 1,
		"version": "v1.1.0",
		"image": "dirextalk/message-server:v1.1.0",
		"image_digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		"upgrade_from": [">=v1.0.0 <v1.1.0"],
		"schema_version": 2,
		"schema_compat_version": 1,
		"minimum_client_version": "v1.0.0",
		"maximum_client_version_exclusive": "v2.0.0",
		"backup_required": true,
		"rollback_supported": true,
		"rollback_mode": "restore_backup",
		"release_notes_url": "https://github.com/YingSuiAI/dirextalk-message-server/releases/tag/v1.1.0"
	}`
}

func TestValidateManifestAcceptsCanonicalRelease(t *testing.T) {
	manifest, err := ValidateManifest([]byte(validManifestJSON()))
	if err != nil {
		t.Fatalf("ValidateManifest: %v", err)
	}
	if manifest.Version != "v1.1.0" || manifest.ImageDigest == "" {
		t.Fatalf("unexpected manifest: %#v", manifest)
	}
}

func TestValidateManifestRejectsUnknownAndUnsafeFields(t *testing.T) {
	for _, extra := range []string{
		`"shell":"sh -c attacker"`,
		`"compose_path":"/tmp/compose.yml"`,
		`"service":"attacker"`,
	} {
		data := strings.TrimSuffix(validManifestJSON(), "}") + "," + extra + "}"
		if _, err := ValidateManifest([]byte(data)); err == nil || !strings.Contains(err.Error(), "unknown field") {
			t.Fatalf("expected unknown field rejection for %s, got %v", extra, err)
		}
	}
}

func TestValidateManifestRejectsTagDigestAndUpgradeMismatch(t *testing.T) {
	tests := []struct {
		name string
		old  string
		new  string
	}{
		{"image tag", "dirextalk/message-server:v1.1.0", "dirextalk/message-server:v9.9.9"},
		{"digest", "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "sha256:ABC"},
		{"target in upgrade range", ">=v1.0.0 <v1.1.0", ">=v1.0.0 <=v1.1.0"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := ValidateManifest([]byte(strings.Replace(validManifestJSON(), tc.old, tc.new, 1))); err == nil {
				t.Fatal("expected validation error")
			}
		})
	}
}

func TestValidateManifestRejectsReleaseURLUserInfo(t *testing.T) {
	data := strings.Replace(validManifestJSON(), "https://github.com/", "https://attacker@github.com/", 1)
	if _, err := ValidateManifest([]byte(data)); err == nil {
		t.Fatal("expected release URL userinfo to be rejected")
	}
}

func TestValidateUpgradeFromRejectsDowngradeEvenWhenConstraintMatches(t *testing.T) {
	manifest, err := ValidateManifest([]byte(validManifestJSON()))
	if err != nil {
		t.Fatal(err)
	}
	manifest.UpgradeFrom = []string{">=v1.2.0"}
	if err := manifest.Validate(); err != nil {
		t.Fatalf("test manifest must remain structurally valid: %v", err)
	}
	if err := manifest.ValidateUpgradeFrom("v1.2.0"); err == nil {
		t.Fatal("an upgrade plan must not accept a current version above its target")
	}
}

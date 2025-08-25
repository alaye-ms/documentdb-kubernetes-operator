// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package config

import (
	"strconv"

	"github.com/cloudnative-pg/cnpg-i-machinery/pkg/pluginhelper/common"
	"github.com/cloudnative-pg/cnpg-i-machinery/pkg/pluginhelper/validation"
	"github.com/cloudnative-pg/cnpg-i/pkg/operator"
)

// Plugin parameter keys
const (
	ImageParam           = "image"           // string
	ReplicationHostParam = "replicationHost" // primary host
	SynchronousParam     = "synchronous"     // bool
	WalDirectoryParam    = "walDirectory"    // directory where WAL is stored
)

const (
	defaultImage  = "ghcr.io/cloudnative-pg/postgresql:16"
	defaultWalDir = "/var/lib/postgres/wal"
	defaultSync   = false
)

// Configuration represents the plugin configuration parameters controlling the wal receiver pod
type Configuration struct {
	Image           string
	ReplicationHost string
	Synchronous     bool
	WalDirectory    string
}

// FromParameters builds a plugin configuration from the configuration parameters
func FromParameters(helper *common.Plugin) (*Configuration, []*operator.ValidationError) {
	validationErrors := make([]*operator.ValidationError, 0)

	cfg := &Configuration{}

	// image
	if raw, present := helper.Parameters[ImageParam]; present && raw != "" {
		cfg.Image = raw
	} else {
		cfg.Image = "ghcr.io/cloudnative-pg/postgresql:16"
	}

	if raw, present := helper.Parameters[ReplicationHostParam]; present && raw != "" {
		cfg.ReplicationHost = raw
	} else {
		validationErrors = append(validationErrors, validation.BuildErrorForParameter(helper, ReplicationHostParam, "No replication host provided"))
	}

	if raw, present := helper.Parameters[SynchronousParam]; present && raw != "" {
		v, err := strconv.ParseBool(raw)
		if err != nil {
			validationErrors = append(validationErrors, validation.BuildErrorForParameter(helper, SynchronousParam, err.Error()))
		} else {
			cfg.Synchronous = v
		}
	} else {
		cfg.Synchronous = false
	}

	if raw, present := helper.Parameters[WalDirectoryParam]; present && raw != "" {
		cfg.WalDirectory = raw
	} else {
		cfg.WalDirectory = "/var/lib/postgres/wal"
	}

	return cfg, validationErrors
}

// ValidateChanges validates the changes between the old configuration to the new configuration
func ValidateChanges(_ *Configuration, _ *Configuration, _ *common.Plugin) []*operator.ValidationError {
	return nil
}

// ToParameters serialize the configuration back to plugin parameters
func (c *Configuration) ToParameters() (map[string]string, error) {
	params := map[string]string{}
	params[ImageParam] = c.Image
	params[ReplicationHostParam] = c.ReplicationHost
	params[SynchronousParam] = strconv.FormatBool(c.Synchronous)
	params[WalDirectoryParam] = c.WalDirectory
	return params, nil
}

func ValidateParams(helper *common.Plugin) []*operator.ValidationError {
	validationErrors := make([]*operator.ValidationError, 0)
	if raw, present := helper.Parameters[ReplicationHostParam]; !present || raw == "" {
		validationErrors = append(validationErrors, validation.BuildErrorForParameter(helper, ReplicationHostParam, "No replication host provided"))
	}
	if raw, present := helper.Parameters[SynchronousParam]; present && raw != "" {
		_, err := strconv.ParseBool(raw)
		if err != nil {
			validationErrors = append(validationErrors, validation.BuildErrorForParameter(helper, SynchronousParam, err.Error()))
		}
	}
	return validationErrors
}

// applyDefaults fills the configuration with the defaults
func (c *Configuration) applyDefaults(helper *common.Plugin) {
	if c.Image == "" {
		c.Image = defaultImage
	}
	if c.WalDirectory == "" {
		c.WalDirectory = defaultWalDir
	}
	// By default synchronous true if not explicitly set
	if helper.Parameters[SynchronousParam] == "" { // not provided
		c.Synchronous = true
	}
}

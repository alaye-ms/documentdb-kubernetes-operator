// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

// Package lifecycle implements the lifecycle hooks
package lifecycle

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	apiv1 "github.com/cloudnative-pg/api/pkg/api/v1"
	"github.com/cloudnative-pg/cnpg-i-machinery/pkg/pluginhelper/common"
	"github.com/cloudnative-pg/cnpg-i-machinery/pkg/pluginhelper/decoder"
	"github.com/cloudnative-pg/cnpg-i/pkg/lifecycle"
	"github.com/cloudnative-pg/machinery/pkg/log"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/util/intstr"

	// ctrlclient "sigs.k8s.io/controller-runtime/pkg/client" // not needed currently

	"github.com/documentdb/cnpg-i-wal-replica/internal/config"
	"github.com/documentdb/cnpg-i-wal-replica/internal/k8sclient"
	"github.com/documentdb/cnpg-i-wal-replica/internal/utils"
	"github.com/documentdb/cnpg-i-wal-replica/pkg/metadata"
)

// Implementation is the implementation of the lifecycle handler
type Implementation struct {
	lifecycle.UnimplementedOperatorLifecycleServer
}

// GetCapabilities exposes the lifecycle capabilities
func (impl Implementation) GetCapabilities(
	_ context.Context,
	_ *lifecycle.OperatorLifecycleCapabilitiesRequest,
) (*lifecycle.OperatorLifecycleCapabilitiesResponse, error) {
	return &lifecycle.OperatorLifecycleCapabilitiesResponse{
		// We only watch the Cluster object so we can create a separate Deployment / Pod
		LifecycleCapabilities: []*lifecycle.OperatorLifecycleCapabilities{
			{
				Group: "postgresql.cnpg.io", // group of Cluster CRD
				Kind:  "Cluster",
				OperationTypes: []*lifecycle.OperatorOperationType{{
					Type: lifecycle.OperatorOperationType_TYPE_CREATE,
				}, {
					Type: lifecycle.OperatorOperationType_TYPE_PATCH,
				}, {
					Type: lifecycle.OperatorOperationType_TYPE_UPDATE,
				}},
			},
		},
	}, nil
}

// LifecycleHook is called when creating Kubernetes services
func (impl Implementation) LifecycleHook(
	ctx context.Context,
	request *lifecycle.OperatorLifecycleRequest,
) (*lifecycle.OperatorLifecycleResponse, error) {
	kind, err := utils.GetKind(request.GetObjectDefinition())
	if err != nil {
		return nil, err
	}
	operation := request.GetOperationType().GetType().Enum()
	if operation == nil {
		return nil, errors.New("no operation set")
	}

	if kind == "Cluster" {
		return impl.reconcileCluster(ctx, request, *operation)
	}
	return &lifecycle.OperatorLifecycleResponse{}, nil
}

// LifecycleHook is called when creating Kubernetes services
// reconcileCluster ensures the pg_receivewal Deployment exists when enabled
func (impl Implementation) reconcileCluster(
	ctx context.Context,
	request *lifecycle.OperatorLifecycleRequest,
	operation lifecycle.OperatorOperationType_Type,
) (*lifecycle.OperatorLifecycleResponse, error) {
	logger := log.FromContext(ctx).WithName("wal-replica-lifecycle")
	cluster, err := decoder.DecodeClusterLenient(request.GetObjectDefinition())
	if err != nil {
		return nil, err
	}

	helper := common.NewPlugin(*cluster, metadata.PluginName)
	configuration, valErrs := config.FromParameters(helper)
	if len(valErrs) > 0 {
		return nil, valErrs[0]
	}

	// Just log if disabled and return noop
	if helper.PluginIndex < 0 {
		logger.Debug("wal replica plugin not present in spec.")
		return &lifecycle.OperatorLifecycleResponse{}, nil
	}

	// Build Deployment name unique per cluster
	depName := fmt.Sprintf("%s-wal-receiver", cluster.Name)
	namespace := cluster.Namespace
	cl := k8sclient.MustGet()

	// derive primary host if not provided: <cluster>-rw (CNPG service naming) or cluster.Status.CurrentPrimary
	replHost := configuration.ReplicationHost
	if replHost == "" {
		if cluster.Status.CurrentPrimary != "" {
			// cluster.Status.CurrentPrimary is in the form <cluster>-<podIdx>
			// Postgres primary service in CNPG is <cluster>-rw
			replHost = fmt.Sprintf("%s-rw", cluster.Name)
		} else {
			replHost = fmt.Sprintf("%s-rw", cluster.Name)
		}
	}

	walDir := configuration.WalDirectory
	cmd := []string{"/usr/bin/pg_receivewal", "--no-loop", "--directory", walDir, "--host", replHost, "--user", "streaming_replica"}

	// Add synchronous flag if requested
	if configuration.Synchronous {
		cmd = append(cmd, "--synchronous")
	}

	// Create or patch Deployment
	existing := &appsv1.Deployment{}
	err = cl.Get(ctx, types.NamespacedName{Name: depName, Namespace: namespace}, existing)
	if err != nil {
		// create new deployment
		replicas := int32(1)
		dep := &appsv1.Deployment{
			ObjectMeta: metav1.ObjectMeta{
				Name:      depName,
				Namespace: namespace,
				Labels: map[string]string{
					"app":             depName,
					"cnpg.io/cluster": cluster.Name,
				},
			},
			Spec: appsv1.DeploymentSpec{
				Replicas: &replicas,
				Selector: &metav1.LabelSelector{MatchLabels: map[string]string{"app": depName}},
				Template: corev1.PodTemplateSpec{
					ObjectMeta: metav1.ObjectMeta{Labels: map[string]string{"app": depName}},
					Spec: corev1.PodSpec{
						Containers: []corev1.Container{{
							Name:  "wal-receiver",
							Image: configuration.Image,
							Args:  cmd,
							Env: []corev1.EnvVar{{
								Name:      "PGPASSWORD",
								ValueFrom: &corev1.EnvVarSource{SecretKeyRef: &corev1.SecretKeySelector{LocalObjectReference: corev1.LocalObjectReference{Name: configuration.ReplicationPasswordSecretName}, Key: configuration.ReplicationPasswordSecretKey}},
							}},
							Ports:          []corev1.ContainerPort{{Name: "metrics", ContainerPort: 9187}},
							ReadinessProbe: &corev1.Probe{ProbeHandler: corev1.ProbeHandler{Exec: &corev1.ExecAction{Command: []string{"/bin/sh", "-c", "test -d " + walDir}}}, PeriodSeconds: 30},
						}},
						RestartPolicy: corev1.RestartPolicyAlways,
					},
				},
			},
		}
		// optional service for metrics
		svc := &corev1.Service{ObjectMeta: metav1.ObjectMeta{Name: depName, Namespace: namespace, Labels: map[string]string{"app": depName}}, Spec: corev1.ServiceSpec{Selector: map[string]string{"app": depName}, Ports: []corev1.ServicePort{{Name: "metrics", Port: 9187, TargetPort: intstr.FromInt(9187)}}}}
		if createErr := cl.Create(ctx, dep); createErr != nil {
			logger.Error(createErr, "creating wal receiver deployment")
			return nil, createErr
		}
		_ = cl.Create(ctx, svc) // ignore error if exists
		logger.Info("created wal receiver deployment", "name", depName)
	} else {
		// patch spec if needed
		updated := existing.DeepCopy()
		if len(updated.Spec.Template.Spec.Containers) == 0 || !strings.EqualFold(updated.Spec.Template.Spec.Containers[0].Image, configuration.Image) || !equalStringSlices(updated.Spec.Template.Spec.Containers[0].Args, complete) {
			updated.Spec.Template.Spec.Containers = []corev1.Container{existing.Spec.Template.Spec.Containers[0]}
			updated.Spec.Template.Spec.Containers[0].Image = configuration.Image
			updated.Spec.Template.Spec.Containers[0].Args = complete
			if patchErr := cl.Update(ctx, updated); patchErr != nil {
				logger.Error(patchErr, "updating wal receiver deployment")
				return nil, patchErr
			}
			logger.Info("updated wal receiver deployment", "name", depName)
		}
	}

	// Wait a tiny bit for status changes (non-blocking best-effort)
	_ = ctx
	_ = operation
	return &lifecycle.OperatorLifecycleResponse{}, nil
}

func equalStringSlices(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// Utility to find primary pod name (not currently used, placeholder for future improvements)
func primaryPodName(cluster *apiv1.Cluster) string {
	if cluster == nil {
		return ""
	}
	if cluster.Status.CurrentPrimary != "" {
		return cluster.Status.CurrentPrimary
	}
	return fmt.Sprintf("%s-1", cluster.Name)
}

// simple backoff sleep helper (not used currently)
func sleep(d time.Duration) { time.Sleep(d) }

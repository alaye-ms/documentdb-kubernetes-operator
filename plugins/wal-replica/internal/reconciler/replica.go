package reconciler

import (
	"context"
	"fmt"
	"strings"

	apiv1 "github.com/cloudnative-pg/api/pkg/api/v1"
	"github.com/cloudnative-pg/cnpg-i/pkg/lifecycle"
	"github.com/cloudnative-pg/machinery/pkg/log"
	"github.com/documentdb/cnpg-i-wal-replica/internal/config"
	"github.com/documentdb/cnpg-i-wal-replica/internal/k8sclient"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/util/intstr"
)

func CreateWalReplica(
	ctx context.Context,
	cluster *apiv1.Cluster,
) error {
	logger := log.FromContext(ctx).WithName("CreateWalReplica")

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
	if configuration.Synchronous == config.SynchronousActive {
		cmd = append(cmd, "--synchronous")
	}

	// Create or patch Deployment
	existing := &appsv1.Deployment{}
	err = cl.Get(ctx, types.NamespacedName{Name: depName, Namespace: namespace}, existing)
	if err != nil {
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
				Selector: &metav1.LabelSelector{MatchLabels: map[string]string{"app": depName}},
				Template: corev1.PodTemplateSpec{
					ObjectMeta: metav1.ObjectMeta{Labels: map[string]string{"app": depName}},
					Spec: corev1.PodSpec{
						Containers: []corev1.Container{{
							Name:           "wal-receiver",
							Image:          configuration.Image,
							Args:           cmd,
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
		if len(updated.Spec.Template.Spec.Containers) == 0 || !strings.EqualFold(updated.Spec.Template.Spec.Containers[0].Image, configuration.Image) || !equalStringSlices(updated.Spec.Template.Spec.Containers[0].Args, cmd) {
			updated.Spec.Template.Spec.Containers = []corev1.Container{existing.Spec.Template.Spec.Containers[0]}
			updated.Spec.Template.Spec.Containers[0].Image = configuration.Image
			updated.Spec.Template.Spec.Containers[0].Args = cmd
			if patchErr := cl.Update(ctx, updated); patchErr != nil {
				logger.Error(patchErr, "updating wal receiver deployment")
				return nil, patchErr
			}
			logger.Info("updated wal receiver deployment", "name", depName)
		}
	}

	return &lifecycle.OperatorLifecycleResponse{}, nil
}

package test

import (
	"os"
	"testing"

	"github.com/gruntwork-io/terratest/modules/terraform"
	"github.com/stretchr/testify/assert"
)

func skipUnlessIntegration(t *testing.T) {
	t.Helper()
	if os.Getenv("INTEGRATION_TESTS") != "true" {
		t.Skip("Set INTEGRATION_TESTS=true to run integration tests")
	}
}

// TestClusterModePlan verifies the module plans successfully in cluster mode.
// This does NOT create real AWS resources — it only runs terraform plan.
func TestClusterModePlan(t *testing.T) {
	skipUnlessIntegration(t)

	opts := terraform.WithDefaultRetryableErrors(t, &terraform.Options{
		TerraformDir: "../../",
		Vars: map[string]interface{}{
			"identifier":     "terratest-cluster",
			"rds_identifier": os.Getenv("TEST_RDS_CLUSTER_ID"),
			"is_cluster":     true,
			"up_schedule":    "0 12 ? * MON-FRI *",
			"down_schedule":  "0 0 * * ? *",
		},
		PlanFilePath: "tfplan",
	})

	plan := terraform.InitAndPlanAndShowWithStruct(t, opts)

	// Verify Lambda resource exists in plan
	lambda := plan.ResourcePlannedValuesMap["aws_lambda_function.rds-scheduler"]
	assert.NotNil(t, lambda, "Lambda function should be in plan")
	assert.Equal(t, "python3.12", lambda.AttributeValues["runtime"])

	// Verify IAM role
	role := plan.ResourcePlannedValuesMap["aws_iam_role.rds-scheduler"]
	assert.NotNil(t, role, "IAM role should be in plan")
	assert.Equal(t, "terratest-cluster-rds-scheduler", role.AttributeValues["name"])
}

// TestInstanceModePlan verifies the module plans successfully in instance mode.
func TestInstanceModePlan(t *testing.T) {
	skipUnlessIntegration(t)

	opts := terraform.WithDefaultRetryableErrors(t, &terraform.Options{
		TerraformDir: "../../",
		Vars: map[string]interface{}{
			"identifier":     "terratest-instance",
			"rds_identifier": os.Getenv("TEST_RDS_INSTANCE_ID"),
			"is_cluster":     false,
			"up_schedule":    "0 12 ? * MON-FRI *",
			"down_schedule":  "0 0 * * ? *",
		},
		PlanFilePath: "tfplan",
	})

	plan := terraform.InitAndPlanAndShowWithStruct(t, opts)

	lambda := plan.ResourcePlannedValuesMap["aws_lambda_function.rds-scheduler"]
	assert.NotNil(t, lambda, "Lambda function should be in plan")
}

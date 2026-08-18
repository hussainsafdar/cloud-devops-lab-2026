data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# Jenkins credentials: read access to SSM Parameter Store
#
# Only the IAM permission is managed here, deliberately. An aws_ssm_parameter
# resource would write the secret value into Terraform state, which is exactly
# what "not hardcoded" is meant to prevent. The parameters themselves are
# created out-of-band with the AWS CLI, so the value never lands in this repo,
# in a .tfvars file, or in state.
#
# With this policy attached, the EC2 instances read their secrets through the
# instance profile - no access keys are stored on the boxes at all.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "jenkins_ssm_read" {
  statement {
    sid    = "ReadJenkinsParameters"
    effect = "Allow"

    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
    ]

    # Scoped to this one path rather than "*", so a compromised instance can
    # read its own Jenkins credentials and nothing else in the account.
    #
    # Two ARNs are required, and this catches people out: GetParameter acts on
    # the individual parameter (.../jenkins/admin-password, matched by the /*
    # form), while GetParametersByPath acts on the PATH ITSELF
    # (.../jenkins, with no trailing /*). Granting only the /* form makes
    # GetParametersByPath fail with AccessDenied.
    resources = [
      "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${var.ssm_parameter_prefix}",
      "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${var.ssm_parameter_prefix}/*",
    ]
  }

  # SecureString values are returned still encrypted unless the caller can use
  # the KMS key that wrapped them, so GetParameter alone is not enough:
  # --with-decryption fails with AccessDenied without this statement.
  #
  # Resource must be "*" because IAM does not accept KMS *alias* ARNs, and the
  # aws/ssm key id differs per account. The ViaService condition is what keeps
  # this tight: the role may use the key only for requests arriving through
  # SSM, never for direct KMS calls.
  statement {
    sid       = "DecryptSecureStringsViaSSM"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.aws_region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_policy" "jenkins_ssm_read" {
  name        = "devops-lab-jenkins-ssm-read"
  description = "Read devops-lab application secrets from SSM Parameter Store"
  policy      = data.aws_iam_policy_document.jenkins_ssm_read.json
}

resource "aws_iam_role_policy_attachment" "jenkins_ssm_read" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = aws_iam_policy.jenkins_ssm_read.arn
}

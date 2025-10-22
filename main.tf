provider "aws" {
  region = "us-east-1"
}

terraform {
  required_version = ">= 1.0.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  backend "s3" {
    bucket = "sctp-ce11-tfstate"
    key    = "jiafu-s3-tf-ci.tfstate" #Change this
    region = "us-east-1"
  }
}

data "aws_caller_identity" "current" {}

locals {
  name_prefix = split("/", data.aws_caller_identity.current.arn)[1] #if your name contains any invalid characters like “.”, hardcode this name_prefix value = <YOUR NAME>
  account_id  = data.aws_caller_identity.current.account_id
}

resource "aws_s3_bucket" "s3_tf" {
  bucket = "${local.name_prefix}-s3-tf-bkt-${local.account_id}"
}

resource "aws_s3_bucket_server_side_encryption_configuration" "s3_tf" {
  bucket = aws_s3_bucket.s3_tf.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
      # optionally specify kms_master_key_id = aws_kms_key.mykey.arn
    }
  }
}

resource "aws_sns_topic" "s3_events" {
  name = "${local.name_prefix}-s3-events-${local.account_id}"
}

resource "aws_sns_topic_policy" "allow_s3" {
  arn = aws_sns_topic.s3_events.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowS3Publish"
        Effect    = "Allow"
        Principal = { Service = "s3.amazonaws.com" }
        Action    = "SNS:Publish"
        Resource  = aws_sns_topic.s3_events.arn
        Condition = {
          ArnLike = { "aws:SourceArn" = "arn:aws:s3:::${aws_s3_bucket.s3_tf.bucket}" }
        }
      }
    ]
  })
}

resource "aws_s3_bucket_notification" "s3_notification" {
  bucket = aws_s3_bucket.s3_tf.id

  topic {
    topic_arn = aws_sns_topic.s3_events.arn
    events    = ["s3:ObjectCreated:*"]
    # optional filters:
  }
}

/* resource "aws_s3_bucket" "s3_tf" {
  bucket = "${local.name_prefix}-s3-tf-bkt-${local.account_id}"
}*/

resource "aws_s3_bucket_logging" "s3_tf_logging" {
  bucket        = aws_s3_bucket.s3_tf.id
  target_bucket = aws_s3_bucket.access_logs.id
  target_prefix = "s3_tf/"
}

resource "aws_s3_bucket" "access_logs" {
  bucket = "${local.name_prefix}-s3-access-logs-${local.account_id}"
  tags = {
    Name = "access-logs"
  }
}

resource "aws_s3_bucket_acl" "access_logs_acl" {
  bucket = aws_s3_bucket.access_logs.id
  acl    = "log-delivery-write"
}

/*resource "aws_s3_bucket" "s3_tf" {
  bucket = "${local.name_prefix}-s3-tf-bkt-${local.account_id}"
}*/

resource "aws_s3_bucket_public_access_block" "s3_tf_block" {
  bucket = aws_s3_bucket.s3_tf.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "access_logs_block" {
  bucket = aws_s3_bucket.access_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Optional: enforce at account level (recommended)
resource "aws_s3_account_public_access_block" "account_block" {
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

/*resource "aws_s3_bucket_public_access_block" "s3_tf_block" {
  bucket = aws_s3_bucket.s3_tf.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}*/

/*resource "aws_s3_bucket_public_access_block" "access_logs_block" {
  bucket = aws_s3_bucket.access_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}*/

# Optional: enforce at account level (recommended)
/*resource "aws_s3_account_public_access_block" "account_block" {
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}*/

/*resource "aws_s3_bucket" "s3_tf" {
  bucket = "${local.name_prefix}-s3-tf-bkt-${local.account_id}"

  lifecycle {
    prevent_destroy = false
  }
}*/

resource "aws_s3_bucket_lifecycle_configuration" "s3_tf_lifecycle" {
  bucket = aws_s3_bucket.s3_tf.id

  rule {
    id     = "default-lifecycle"
    status = "Enabled"

    filter {}

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    expiration {
      days = 365
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_versioning" "s3_tf_versioning" {
  bucket = aws_s3_bucket.s3_tf.id

  versioning_configuration {
    status = "Enabled"
  }
}

# provider for replica region (choose target region)
provider "aws" {
  alias  = "replica"
  region = "us-west-2"
}

# destination (replica) bucket in another region
resource "aws_s3_bucket" "s3_tf_replica" {
  provider = aws.replica
  bucket   = "${local.name_prefix}-s3-tf-bkt-replica-${local.account_id}"
}

resource "aws_s3_bucket_acl" "s3_tf_replica_acl" {
  provider = aws.replica
  bucket   = aws_s3_bucket.s3_tf_replica.id
  acl      = "private"
}

# enable versioning on destination (required for CRR)
resource "aws_s3_bucket_versioning" "s3_tf_replica_versioning" {
  provider = aws.replica
  bucket   = aws_s3_bucket.s3_tf_replica.id

  versioning_configuration {
    status = "Enabled"
  }
}

# IAM role S3 will assume to perform replication
resource "aws_iam_role" "s3_replication_role" {
  name = "${local.name_prefix}-s3-replication-role-${local.account_id}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "s3.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

# minimal inline policy for replication permissions (source + destination)
resource "aws_iam_role_policy" "s3_replication_policy" {
  role = aws_iam_role.s3_replication_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetReplicationConfiguration",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.s3_tf.arn
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObjectVersion",
          "s3:GetObjectVersionAcl",
          "s3:GetObjectVersionTagging"
        ]
        Resource = [
          "${aws_s3_bucket.s3_tf.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:ReplicateObject",
          "s3:ReplicateDelete",
          "s3:ReplicateTags",
          "s3:PutObjectAcl"
        ]
        Resource = [
          aws_s3_bucket.s3_tf_replica.arn,
          "${aws_s3_bucket.s3_tf_replica.arn}/*"
        ]
      }
    ]
  })
}

# replication configuration on source bucket
resource "aws_s3_bucket_replication_configuration" "s3_tf_replication" {
  bucket = aws_s3_bucket.s3_tf.id
  role   = aws_iam_role.s3_replication_role.arn

  rule {
    id       = "replicate-to-${replace(aws_s3_bucket.s3_tf_replica.bucket, "-", "_")}"
    status   = "Enabled"
    priority = 1

    filter {}

    destination {
      bucket        = aws_s3_bucket.s3_tf_replica.arn
      storage_class = "STANDARD"
    }
  }
}

# Create KMS key for SNS encryption
resource "aws_kms_key" "sns_encryption" {
  description             = "KMS key for SNS topic encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Enable IAM User Permissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${local.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "Allow SNS to use the key"
        Effect = "Allow"
        Principal = {
          Service = "sns.amazonaws.com"
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey*"
        ]
        Resource = "*"
      }
    ]
  })
}

# Update the existing SNS topic to use KMS encryption
resource "aws_sns_topic" "s3_events1" {
  name              = "${local.name_prefix}-s3-events-${local.account_id}"
  kms_master_key_id = aws_kms_key.sns_encryption.id
}

# Create KMS key for S3 encryption
resource "aws_kms_key" "s3_encryption" {
  description             = "KMS key for S3 bucket encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "s3_tf1" {
  bucket = aws_s3_bucket.s3_tf.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.s3_encryption.arn
      sse_algorithm     = "aws:kms"
    }
  }
}

# Create KMS key for S3 encryption
resource "aws_kms_key" "s3_encryption1" {
  description             = "KMS key for S3 bucket encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

# Main bucket encryption
resource "aws_s3_bucket_server_side_encryption_configuration" "s3_tf2" {
  bucket = aws_s3_bucket.s3_tf.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.s3_encryption.arn
      sse_algorithm     = "aws:kms"
    }
  }
}

# Replica bucket encryption
resource "aws_s3_bucket_server_side_encryption_configuration" "s3_tf_replica" {
  provider = aws.replica
  bucket   = aws_s3_bucket.s3_tf_replica.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.s3_encryption.arn
      sse_algorithm     = "aws:kms"
    }
  }
}

# Access logs bucket
resource "aws_s3_bucket" "access_logs1" {
  bucket = "${local.name_prefix}-s3-access-logs-${local.account_id}"
  tags = {
    Name = "access-logs"
  }
}

# Access logs bucket ACL
resource "aws_s3_bucket_acl" "access_logs_acl1" {
  bucket = aws_s3_bucket.access_logs.id
  acl    = "log-delivery-write"
}

# Main bucket logging
resource "aws_s3_bucket_logging" "s3_tf_logging1" {
  bucket        = aws_s3_bucket.s3_tf.id
  target_bucket = aws_s3_bucket.access_logs.id
  target_prefix = "s3_tf/"
}

# Replica bucket logging
resource "aws_s3_bucket_logging" "s3_tf_replica_logging" {
  provider      = aws.replica
  bucket        = aws_s3_bucket.s3_tf_replica.id
  target_bucket = aws_s3_bucket.access_logs.id
  target_prefix = "s3_tf_replica/"
}

# SNS Topic for S3 events
resource "aws_sns_topic" "s3_events2" {
  name              = "${local.name_prefix}-s3-events-${local.account_id}"
  kms_master_key_id = aws_kms_key.sns_encryption.id
}

# SNS Topic Policy
resource "aws_sns_topic_policy" "allow_s31" {
  arn = aws_sns_topic.s3_events.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowS3Publish"
        Effect    = "Allow"
        Principal = { Service = "s3.amazonaws.com" }
        Action    = "SNS:Publish"
        Resource  = aws_sns_topic.s3_events.arn
        Condition = {
          ArnLike = { "aws:SourceArn" = "arn:aws:s3:::${aws_s3_bucket.s3_tf.bucket}" }
        }
      }
    ]
  })
}

# Main bucket notification
resource "aws_s3_bucket_notification" "s3_tf_notification" {
  bucket = aws_s3_bucket.s3_tf.id

  topic {
    topic_arn = aws_sns_topic.s3_events.arn
    events    = ["s3:ObjectCreated:*", "s3:ObjectRemoved:*"]
  }

  depends_on = [aws_sns_topic_policy.allow_s3]
}

# Replica bucket notification
resource "aws_s3_bucket_notification" "s3_tf_replica_notification" {
  provider = aws.replica
  bucket   = aws_s3_bucket.s3_tf_replica.id

  topic {
    topic_arn = aws_sns_topic.s3_events.arn
    events    = ["s3:ObjectCreated:*", "s3:ObjectRemoved:*"]
  }

  depends_on = [aws_sns_topic_policy.allow_s3]
}

# SNS Topic with KMS encryption
resource "aws_sns_topic" "s3_events2" {
  name              = "${local.name_prefix}-s3-events-${local.account_id}"
  kms_master_key_id = aws_kms_key.sns_encryption.id
}

# SNS Topic Policy allowing S3 to publish
resource "aws_sns_topic_policy" "allow_s32" {
  arn = aws_sns_topic.s3_events.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowS3Publish"
        Effect    = "Allow"
        Principal = { Service = "s3.amazonaws.com" }
        Action    = "SNS:Publish"
        Resource  = aws_sns_topic.s3_events.arn
        Condition = {
          ArnLike = {
            "aws:SourceArn" = [
              "arn:aws:s3:::${aws_s3_bucket.s3_tf.bucket}",
              "arn:aws:s3:::${aws_s3_bucket.s3_tf_replica.bucket}"
            ]
          }
        }
      }
    ]
  })
}

# Main bucket notification
resource "aws_s3_bucket_notification" "s3_tf_notification1" {
  bucket = aws_s3_bucket.s3_tf.id

  topic {
    topic_arn = aws_sns_topic.s3_events.arn
    events    = ["s3:ObjectCreated:*", "s3:ObjectRemoved:*"]
  }

  depends_on = [aws_sns_topic_policy.allow_s3]
}

# Replica bucket notification
resource "aws_s3_bucket_notification" "s3_tf_replica_notification1" {
  provider = aws.replica
  bucket   = aws_s3_bucket.s3_tf_replica.id

  topic {
    topic_arn = aws_sns_topic.s3_events.arn
    events    = ["s3:ObjectCreated:*", "s3:ObjectRemoved:*"]
  }

  depends_on = [aws_sns_topic_policy.allow_s3]
}

# Main bucket public access block
resource "aws_s3_bucket_public_access_block" "s3_tf_block1" {
  bucket = aws_s3_bucket.s3_tf.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Replica bucket public access block
resource "aws_s3_bucket_public_access_block" "s3_tf_replica_block" {
  provider = aws.replica
  bucket   = aws_s3_bucket.s3_tf_replica.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Access logs bucket public access block
resource "aws_s3_bucket_public_access_block" "access_logs_block1" {
  bucket = aws_s3_bucket.access_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Account-level public access block
resource "aws_s3_account_public_access_block" "account_block1" {
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Main bucket versioning
resource "aws_s3_bucket_versioning" "s3_tf_versioning1" {
  bucket = aws_s3_bucket.s3_tf.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Replica bucket versioning
resource "aws_s3_bucket_versioning" "s3_tf_replica_versioning1" {
  provider = aws.replica
  bucket   = aws_s3_bucket.s3_tf_replica.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Access logs bucket versioning
resource "aws_s3_bucket_versioning" "access_logs_versioning" {
  bucket = aws_s3_bucket.access_logs.id

  versioning_configuration {
    status = "Enabled"
  }
}

// ...existing code...

resource "aws_s3_bucket_lifecycle_configuration" "s3_tf_replica_lifecycle" {
  provider = aws.replica
  bucket   = aws_s3_bucket.s3_tf_replica.id

  rule {
    id     = "replica-default-lifecycle"
    status = "Enabled"
    filter {}

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    expiration {
      days = 365
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "access_logs_lifecycle" {
  bucket = aws_s3_bucket.access_logs.id

  rule {
    id     = "access-logs-default-lifecycle"
    status = "Enabled"
    filter {}

    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    expiration {
      days = 3650
    }

    noncurrent_version_expiration {
      noncurrent_days = 365
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

// ...existing code...

# Main bucket lifecycle
resource "aws_s3_bucket_lifecycle_configuration" "s3_tf_lifecycle1" {
  bucket = aws_s3_bucket.s3_tf.id

  rule {
    id     = "default-lifecycle"
    status = "Enabled"
    filter {}

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    expiration {
      days = 365
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Replica bucket lifecycle
resource "aws_s3_bucket_lifecycle_configuration" "s3_tf_replica_lifecycle1" {
  provider = aws.replica
  bucket   = aws_s3_bucket.s3_tf_replica.id

  rule {
    id     = "replica-default-lifecycle"
    status = "Enabled"
    filter {}

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    expiration {
      days = 365
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Access logs bucket lifecycle
resource "aws_s3_bucket_lifecycle_configuration" "access_logs_lifecycle1" {
  bucket = aws_s3_bucket.access_logs.id

  rule {
    id     = "access-logs-default-lifecycle"
    status = "Enabled"
    filter {}

    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    expiration {
      days = 3650 # 10 years retention for logs
    }

    noncurrent_version_expiration {
      noncurrent_days = 365
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Provider for replica region
provider "aws1" {
  alias  = "replica"
  region = "us-west-2"
}

# Destination (replica) bucket
resource "aws_s3_bucket" "s3_tf_replica1" {
  provider = aws.replica
  bucket   = "${local.name_prefix}-s3-tf-bkt-replica-${local.account_id}"
}

# IAM role for replication
resource "aws_iam_role" "s3_replication_role1" {
  name = "${local.name_prefix}-s3-replication-role-${local.account_id}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "s3.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

# IAM role policy for replication
resource "aws_iam_role_policy" "s3_replication_policy1" {
  role = aws_iam_role.s3_replication_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetReplicationConfiguration",
          "s3:ListBucket"
        ]
        Resource = [aws_s3_bucket.s3_tf.arn]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObjectVersion",
          "s3:GetObjectVersionAcl",
          "s3:GetObjectVersionTagging"
        ]
        Resource = ["${aws_s3_bucket.s3_tf.arn}/*"]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:ReplicateObject",
          "s3:ReplicateDelete",
          "s3:ReplicateTags",
          "s3:PutObjectAcl"
        ]
        Resource = [
          aws_s3_bucket.s3_tf_replica.arn,
          "${aws_s3_bucket.s3_tf_replica.arn}/*"
        ]
      }
    ]
  })
}

# Replication configuration
resource "aws_s3_bucket_replication_configuration" "s3_tf_replication1" {
  bucket = aws_s3_bucket.s3_tf.id
  role   = aws_iam_role.s3_replication_role.arn

  rule {
    id       = "replicate_everything"
    status   = "Enabled"
    priority = 1

    filter {}

    destination {
      bucket        = aws_s3_bucket.s3_tf_replica.arn
      storage_class = "STANDARD"
    }
  }

  depends_on = [aws_s3_bucket_versioning.s3_tf_versioning]
}
output "state_bucket_name" {
  description = "Bucket name to set as backend `bucket` in the root backend.tf."
  value       = oci_objectstorage_bucket.tfstate.name
}

output "namespace" {
  description = "Object Storage namespace (part of the S3-compatible endpoint)."
  value       = data.oci_objectstorage_namespace.ns.namespace
}

output "s3_compat_endpoint" {
  description = "Paste into the root backend.tf `endpoints.s3`."
  value       = "https://${data.oci_objectstorage_namespace.ns.namespace}.compat.objectstorage.${var.region}.oraclecloud.com"
}

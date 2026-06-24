# The Object Storage namespace is account-wide and derived, not chosen.
data "oci_objectstorage_namespace" "ns" {
  compartment_id = var.compartment_ocid
}

# Private, versioned bucket that holds the root module's remote tfstate.
# Versioning keeps state history so a bad apply can be rolled back object-side.
resource "oci_objectstorage_bucket" "tfstate" {
  compartment_id = var.compartment_ocid
  namespace      = data.oci_objectstorage_namespace.ns.namespace
  name           = var.state_bucket_name
  access_type    = "NoPublicAccess"
  versioning     = "Enabled"
}

terraform {
  backend "oci" {
    bucket    = "tf-state-zekinhas"
    namespace = "gr2g4g6jibse"
    region    = "sa-saopaulo-1"
    key       = "terraform.tfstate"
  }
}

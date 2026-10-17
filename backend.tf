terraform {
  backend "oci" {
    bucket    = "<seu-bucket>"
    namespace = "<name-space-do-bucket>"
    region    = "<sua-regiao>"
    key       = "<path-e-nome-do-arquivo>"
  }
}

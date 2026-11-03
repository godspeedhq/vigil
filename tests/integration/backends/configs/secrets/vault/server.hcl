# HashiCorp Vault for Vigil's store tests (compose.secrets.yaml): integrated
# storage (raft, one node) on the vault-data volume, TLS from the test CA.
# The same as OpenBao's, so the two are tested alike. For this test
# environment only.

ui            = false
disable_mlock = true
api_addr      = "https://127.0.0.1:8200"
cluster_addr  = "https://127.0.0.1:8201"

storage "raft" {
  path    = "/vault/file"
  node_id = "vault"
}

listener "tcp" {
  address       = "0.0.0.0:8200"
  tls_cert_file = "/tls/server.pem"
  tls_key_file  = "/tls/server-key.pem"
}

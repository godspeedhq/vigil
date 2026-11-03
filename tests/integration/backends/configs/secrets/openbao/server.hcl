# OpenBao for Vigil's store tests (compose.secrets.yaml): integrated storage
# (raft, one node) on the openbao-data volume, TLS from the test CA. OpenBao
# 2 has no file storage. For this test environment only.

ui            = false
disable_mlock = true
api_addr      = "https://127.0.0.1:8200"
cluster_addr  = "https://127.0.0.1:8201"

storage "raft" {
  path    = "/openbao/file"
  node_id = "openbao"
}

listener "tcp" {
  address       = "0.0.0.0:8200"
  tls_cert_file = "/tls/server.pem"
  tls_key_file  = "/tls/server-key.pem"
}

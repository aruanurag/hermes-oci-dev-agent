output "instance_id" { value = oci_core_instance.hermes.id }
output "private_ip" { value = oci_core_instance.hermes.private_ip }
output "bastion_id" { value = oci_bastion_bastion.this.id }
output "dashboard_url_after_tunnel" { value = "http://localhost:9119" }

variable "image_tag" {
  description = "The tag of jenkins image"
  type        = string
}

variable "account_id" {
  description = "The aws account id"
  type        = string
}

variable "region" {
  description = "The AWS region"
  type        = string
}

variable "dns_hosted_zone_id" {
  description = "The DNS hosted zone id"
  type        = string
}

variable "dns_service_name" {
  description = "The DNS service name"
  type        = string
}
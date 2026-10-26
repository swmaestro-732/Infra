module "crawler_ecr" {
  source  = "../../modules/ecr"
  name    = local.name
  service = "crawler"
}

module "crawler" {
  source = "../../modules/crawler"

  name               = local.name
  environment        = "prod"
  vpc_id             = module.network.vpc_id
  subnet_ids         = module.network.app_subnet_ids
  aws_region         = var.aws_region
  desired_capacity   = 1
  enabled            = true
  ecr_repository_url = module.crawler_ecr.repository_url
  ecr_repository_arn = module.crawler_ecr.repository_arn
  queue_url          = module.crawl_results_queue.queue_url
  queue_arn          = module.crawl_results_queue.queue_arn

  # Reader output 은 host:port 형식. writer 자격증명은 크롤러 역할에 부여하지 않는다.
  db_url       = "jdbc:postgresql://${module.rds.reader_endpoint}/chilsami"
  media_bucket = module.media.bucket_name
  cdn_base_url = "https://${module.media.cdn_domain_name}"
}

# YACE 에 AWS/AutoScaling 수집이 없어 InService=0 15분 Grafana 알림은 이번 변경에서 생략한다.

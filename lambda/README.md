# block_ddos.py

CloudWatch Alarm(RejectCount>=20)이 SNS를 통해 트리거하는 Lambda 함수.
VPC Flow Logs에서 최근 5분간 REJECT가 가장 많은 출발지 IP를 조회하여,
NACL(acl-0736797994d58420f)의 90번 규칙으로 자동 차단한다.

IAM 역할에는 AmazonEC2FullAccess, CloudWatchLogsReadOnlyAccess가 연결되어 있다.
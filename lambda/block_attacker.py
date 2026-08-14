import boto3
import time
from datetime import datetime, timedelta

logs_client = boto3.client('logs')
ec2_client = boto3.client('ec2')

LOG_GROUP = 'soc-3tier-flowlogs'
NACL_ID = ''  # NACL ID, Terraform이 환경변수로 주입 예정
BLOCK_RULE_NUMBER = 50


def find_top_offender_ip():
    """최근 1분간 REJECT 로그에서 가장 빈번한 출발지 IP를 찾는다."""
    end_time = int(time.time() * 1000)
    start_time = end_time - 60 * 1000

    query = """
    fields @message
    | filter @message like /REJECT/
    | parse @message "* * * * * * * * * * * * * *" as ver, account, eni, srcip, dstip, srcport, dstport, protocol, packets, bytes, start, end, action, status
    | stats count(*) as cnt by srcip
    | sort cnt desc
    | limit 1
    """

    start_query = logs_client.start_query(
        logGroupName=LOG_GROUP,
        startTime=start_time,
        endTime=end_time,
        queryString=query
    )
    query_id = start_query['queryId']

    # 쿼리 완료 대기 (최대 10초)
    for _ in range(10):
        result = logs_client.get_query_results(queryId=query_id)
        if result['status'] == 'Complete':
            break
        time.sleep(1)

    if result['results']:
        for field in result['results'][0]:
            if field['field'] == 'srcip':
                return field['value']
    return None


def block_ip(ip_address):
    """NACL에 해당 IP를 차단하는 Deny 규칙을 추가한다."""
    import os
    nacl_id = os.environ['NACL_ID']

    ec2_client.create_network_acl_entry(
        NetworkAclId=nacl_id,
        RuleNumber=BLOCK_RULE_NUMBER,
        Protocol='-1',
        RuleAction='deny',
        Egress=False,
        CidrBlock=f'{ip_address}/32'
    )


def lambda_handler(event, context):
    offender_ip = find_top_offender_ip()

    if not offender_ip:
        print("차단 대상 IP를 찾지 못했습니다. (알람은 발생했으나 로그 조회 결과 없음)")
        return {"status": "no_offender_found"}

    try:
        block_ip(offender_ip)
        print(f"[AUTO-BLOCK] IP {offender_ip} 를 NACL 규칙 {BLOCK_RULE_NUMBER}번으로 차단했습니다. "
              f"시각: {datetime.utcnow().isoformat()}")
        return {"status": "blocked", "ip": offender_ip}
    except Exception as e:
        print(f"[ERROR] IP {offender_ip} 차단 실패: {str(e)}")
        return {"status": "error", "ip": offender_ip, "error": str(e)}
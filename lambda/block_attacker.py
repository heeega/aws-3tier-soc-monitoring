import boto3
import time
from datetime import datetime

logs_client = boto3.client('logs')
ec2_client = boto3.client('ec2')

LOG_GROUP = 'soc-3tier-flowlogs'
BLOCK_RULE_START = 50
BLOCK_RULE_END = 99


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


def get_next_available_rule_number(nacl_id):
    """NACL의 기존 규칙 중 비어있는 가장 작은 번호(50~99)를 찾는다."""
    response = ec2_client.describe_network_acls(NetworkAclIds=[nacl_id])
    existing_numbers = {
        entry['RuleNumber']
        for entry in response['NetworkAcls'][0]['Entries']
        if not entry['Egress']
    }
    for num in range(BLOCK_RULE_START, BLOCK_RULE_END + 1):
        if num not in existing_numbers:
            return num
    return None  # 규칙 공간이 다 찼을 경우


def is_already_blocked(nacl_id, ip_address):
    """이 IP가 이미 차단되어 있는지 확인한다."""
    response = ec2_client.describe_network_acls(NetworkAclIds=[nacl_id])
    for entry in response['NetworkAcls'][0]['Entries']:
        if not entry['Egress'] and entry.get('CidrBlock') == f'{ip_address}/32':
            return True
    return False


def block_ip(ip_address):
    """NACL에 해당 IP를 차단하는 Deny 규칙을 추가한다. 이미 차단되어 있으면 건너뛴다."""
    import os
    nacl_id = os.environ['NACL_ID']

    if is_already_blocked(nacl_id, ip_address):
        print(f"[SKIP] IP {ip_address} 는 이미 차단되어 있습니다.")
        return "already_blocked"

    rule_number = get_next_available_rule_number(nacl_id)
    if rule_number is None:
        raise Exception("사용 가능한 NACL 규칙 번호가 없습니다 (50~99 모두 사용 중)")

    ec2_client.create_network_acl_entry(
        NetworkAclId=nacl_id,
        RuleNumber=rule_number,
        Protocol='-1',
        RuleAction='deny',
        Egress=False,
        CidrBlock=f'{ip_address}/32'
    )
    return rule_number


def lambda_handler(event, context):
    offender_ip = find_top_offender_ip()

    if not offender_ip:
        print("차단 대상 IP를 찾지 못했습니다. (알람은 발생했으나 로그 조회 결과 없음)")
        return {"status": "no_offender_found"}

    try:
        result = block_ip(offender_ip)
        if result == "already_blocked":
            return {"status": "already_blocked", "ip": offender_ip}

        print(f"[AUTO-BLOCK] IP {offender_ip} 를 NACL 규칙 {result}번으로 차단했습니다. "
              f"시각: {datetime.utcnow().isoformat()}")
        return {"status": "blocked", "ip": offender_ip, "rule_number": result}
    except Exception as e:
        print(f"[ERROR] IP {offender_ip} 차단 실패: {str(e)}")
        return {"status": "error", "ip": offender_ip, "error": str(e)}
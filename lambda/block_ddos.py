import boto3
import time

ec2 = boto3.client('ec2', region_name='ap-northeast-2')
logs = boto3.client('logs', region_name='ap-northeast-2')

LOG_GROUP = '/vpc/web-tier-flowlogs'
NACL_ID = 'acl-0736797994d58420f'
TOP_N = 5  # 한 번에 차단할 최대 IP 개수
BASE_RULE_NUMBER = 90  # 90, 89, 88, 87, 86 순으로 사용

def get_top_attacker_ips(limit=TOP_N):
    """최근 5분간 REJECT가 가장 많은 출발지 IP 상위 N개 조회"""
    query = f"""
    fields srcAddr, action
    | filter action = "REJECT"
    | stats count(*) as rejectCount by srcAddr
    | sort rejectCount desc
    | limit {limit}
    """
    start_query = logs.start_query(
        logGroupName=LOG_GROUP,
        startTime=int(time.time()) - 300,
        endTime=int(time.time()),
        queryString=query
    )
    query_id = start_query['queryId']

    result = {'status': 'Running'}
    for _ in range(10):
        result = logs.get_query_results(queryId=query_id)
        if result['status'] == 'Complete':
            break
        time.sleep(1)

    ip_list = []
    for row in result.get('results', []):
        for field in row:
            if field['field'] == 'srcAddr':
                ip_list.append(field['value'])
    return ip_list

def get_existing_deny_ips():
    """이미 NACL에 등록된 Deny IP 목록 조회 (중복 방지)"""
    response = ec2.describe_network_acls(NetworkAclIds=[NACL_ID])
    existing_ips = set()
    for entry in response['NetworkAcls'][0]['Entries']:
        if entry['RuleAction'] == 'deny' and not entry['Egress']:
            existing_ips.add(entry.get('CidrBlock', ''))
    return existing_ips

def block_ip_in_nacl(ip_address, rule_number):
    """해당 IP를 NACL에서 지정된 규칙 번호로 차단"""
    return ec2.create_network_acl_entry(
        NetworkAclId=NACL_ID,
        RuleNumber=rule_number,
        Protocol='-1',
        RuleAction='deny',
        Egress=False,
        CidrBlock=f'{ip_address}/32'
    )

def lambda_handler(event, context):
    attacker_ips = get_top_attacker_ips()

    if not attacker_ips:
        return {'statusCode': 200, 'body': 'No attacker IP found'}

    existing_ips = get_existing_deny_ips()
    blocked = []
    skipped = []
    errors = []

    rule_number = BASE_RULE_NUMBER
    for ip in attacker_ips:
        cidr = f'{ip}/32'
        if cidr in existing_ips:
            skipped.append(ip)
            continue
        try:
            block_ip_in_nacl(ip, rule_number)
            blocked.append(ip)
            rule_number -= 1  # 다음 IP는 규칙 번호 1 감소 (90 → 89 → 88 ...)
        except Exception as e:
            errors.append(f"{ip}: {str(e)}")

    message = f"Blocked: {blocked} / Skipped(already blocked): {skipped} / Errors: {errors}"
    print(message)
    return {'statusCode': 200, 'body': message}
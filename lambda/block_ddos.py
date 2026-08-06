import boto3
import time

ec2 = boto3.client('ec2', region_name='ap-northeast-2')
logs = boto3.client('logs', region_name='ap-northeast-2')

LOG_GROUP = '/vpc/web-tier-flowlogs'
NACL_ID = 'acl-0736797994d58420f'

def get_top_attacker_ip():
    """최근 5분간 REJECT가 가장 많은 출발지 IP 조회"""
    query = """
    fields srcAddr, action
    | filter action = "REJECT"
    | stats count(*) as rejectCount by srcAddr
    | sort rejectCount desc
    | limit 1
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

    if result.get('results'):
        for field in result['results'][0]:
            if field['field'] == 'srcAddr':
                return field['value']
    return None

def block_ip_in_nacl(ip_address):
    """해당 IP를 NACL에서 차단 (규칙 번호 90 - 기본 Allow(100)보다 낮은 우선순위)"""
    response = ec2.create_network_acl_entry(
        NetworkAclId=NACL_ID,
        RuleNumber=90,
        Protocol='-1',
        RuleAction='deny',
        Egress=False,
        CidrBlock=f'{ip_address}/32'
    )
    return response

def lambda_handler(event, context):
    attacker_ip = get_top_attacker_ip()

    if not attacker_ip:
        return {'statusCode': 200, 'body': 'No attacker IP found'}

    try:
        block_ip_in_nacl(attacker_ip)
        message = f"Blocked attacker IP: {attacker_ip}"
    except Exception as e:
        message = f"Error blocking IP {attacker_ip}: {str(e)}"

    print(message)
    return {'statusCode': 200, 'body': message}
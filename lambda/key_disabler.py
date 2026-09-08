import boto3
import time
from datetime import datetime

logs_client = boto3.client('logs')
iam_client = boto3.client('iam')

LOG_GROUP = '/aws/cloudtrail/soc-3tier-key-abuse'


def find_suspicious_access_key():
    end_time = int(time.time() * 1000)
    start_time = end_time - 5 * 60 * 1000

    query = """
    fields @message
    | filter errorCode = "Client.DryRunOperation"
    | fields userIdentity.accessKeyId as accessKeyId, sourceIPAddress, eventName
    | sort @timestamp desc
    | limit 1
    """

    start_query = logs_client.start_query(
        logGroupName=LOG_GROUP,
        startTime=start_time,
        endTime=end_time,
        queryString=query
    )
    query_id = start_query['queryId']

    result = None
    for _ in range(10):
        result = logs_client.get_query_results(queryId=query_id)
        if result['status'] == 'Complete':
            break
        time.sleep(1)

    if result and result['results']:
        row = {f['field']: f['value'] for f in result['results'][0]}
        return row.get('accessKeyId'), row.get('sourceIPAddress')
    return None, None


def find_username_by_access_key(access_key_id):
    paginator = iam_client.get_paginator('list_users')
    for page in paginator.paginate():
        for user in page['Users']:
            keys = iam_client.list_access_keys(UserName=user['UserName'])
            for key in keys['AccessKeyMetadata']:
                if key['AccessKeyId'] == access_key_id:
                    return user['UserName']
    return None


def disable_access_key(username, access_key_id):
    iam_client.update_access_key(
        UserName=username,
        AccessKeyId=access_key_id,
        Status='Inactive'
    )


def lambda_handler(event, context):
    access_key_id, source_ip = find_suspicious_access_key()

    if not access_key_id:
        print("suspicious dryrun event not found")
        return {"status": "no_event_found"}

    username = find_username_by_access_key(access_key_id)

    if not username:
        print("owner user not found for access key: " + access_key_id)
        return {"status": "user_not_found", "access_key_id": access_key_id}

    try:
        disable_access_key(username, access_key_id)
        print("[AUTO-DISABLE] user=" + username + " access_key=" + access_key_id +
              " source_ip=" + str(source_ip) + " time=" + datetime.utcnow().isoformat())
        return {"status": "disabled", "username": username, "access_key_id": access_key_id, "source_ip": source_ip}
    except Exception as e:
        print("[ERROR] disable failed: " + str(e))
        return {"status": "error", "error": str(e)}
import base64
import gzip
import json
import os
import urllib3
from datetime import datetime

http = urllib3.PoolManager()

ES_HOST = os.environ.get('ES_HOST', 'http://10.0.11.219:9200')
INDEX_PREFIX = 'vpc-flowlogs'


def lambda_handler(event, context):
    # CloudWatch Logs 구독 필터는 base64 + gzip으로 압축된 데이터를 보낸다
    compressed_payload = base64.b64decode(event['awslogs']['data'])
    uncompressed_payload = gzip.decompress(compressed_payload)
    log_data = json.loads(uncompressed_payload)

    log_events = log_data.get('logEvents', [])
    if not log_events:
        return {"status": "no_events"}

    index_name = f"{INDEX_PREFIX}-{datetime.utcnow().strftime('%Y.%m.%d')}"

    bulk_body = ""
    for log_event in log_events:
        message = log_event['message']
        fields = message.split()

        # VPC Flow Log 기본 포맷 파싱
        # version account-id interface-id srcaddr dstaddr srcport dstport protocol packets bytes start end action log-status
        if len(fields) < 14:
            continue

        doc = {
            "version": fields[0],
            "account_id": fields[1],
            "interface_id": fields[2],
            "srcaddr": fields[3],
            "dstaddr": fields[4],
            "srcport": fields[5],
            "dstport": fields[6],
            "protocol": fields[7],
            "packets": fields[8],
            "bytes": fields[9],
            "start": int(fields[10]),
            "end": int(fields[11]),
            "action": fields[12],
            "log_status": fields[13],
            "@timestamp": datetime.utcfromtimestamp(int(fields[10])).isoformat()
        }

        bulk_body += json.dumps({"index": {"_index": index_name}}) + "\n"
        bulk_body += json.dumps(doc) + "\n"

    if not bulk_body:
        return {"status": "no_valid_records"}

    response = http.request(
        'POST',
        f"{ES_HOST}/_bulk",
        body=bulk_body.encode('utf-8'),
        headers={'Content-Type': 'application/x-ndjson'}
    )

    print(f"Indexed {len(log_events)} events, ES response status: {response.status}")

    return {"status": "success", "indexed": len(log_events), "es_status": response.status}
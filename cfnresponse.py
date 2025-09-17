import json
import requests

SUCCESS = "SUCCESS"
FAILED = "FAILED"

def send(event, context, responseStatus, responseData, physicalResourceId=None, noEcho=False, reason=None):
    responseUrl = event['ResponseURL']

    print(f"Sending {responseStatus} to {responseUrl} with data: {responseData}")

    responseBody = {
        'Status': responseStatus,
        'Reason': reason or f"See the details in CloudWatch Log Stream: {context.log_stream_name}",
        'PhysicalResourceId': physicalResourceId or context.log_stream_name,
        'StackId': event['StackId'],
        'RequestId': event['RequestId'],
        'LogicalResourceId': event['LogicalResourceId'],
        'NoEcho': noEcho,
        'Data': responseData
    }

    json_responseBody = json.dumps(responseBody)

    headers = {
        'content-type': 'application/json',
        'content-length': str(len(json_responseBody))
    }

    try:
        if not responseUrl.startswith("https://"):
            raise ValueError("Response URL must use HTTPS scheme")
        response = requests.put(responseUrl, data=json_responseBody, headers=headers, timeout=10)
        response.raise_for_status()
        print(f"Status code: {response.status_code}, reason: {response.reason}")
    except ImportError as e:
        print(f"Failed to import requests module: {str(e)}")
        raise
    except requests.exceptions.RequestException as e:
        print(f"send(..) failed with exception: {str(e)}")
        raise
    except ValueError as e:
        print(f"Invalid response URL: {str(e)}")
        raise
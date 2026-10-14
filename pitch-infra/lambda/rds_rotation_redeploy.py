import os
import boto3

ecs = boto3.client("ecs")


def lambda_handler(event, context):
    cluster = os.environ["ECS_CLUSTER"]
    service = os.environ["ECS_SERVICE"]

    response = ecs.update_service(
        cluster=cluster,
        service=service,
        forceNewDeployment=True,
    )

    return {
        "statusCode": 200,
        "cluster": cluster,
        "service": service,
        "deploymentId": response["service"]["deployments"][0]["id"],
    }

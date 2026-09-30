#!/usr/bin/env python3
"""Finalize deleting, backed-up KafkaTopics while their broker is stopped."""
import json
import os
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent / 'stateful'))
import common
import control


def release(manifest_path):
    topics = common.get('kafkatopics', namespace='kafka')['items']
    if not topics:
        return []
    manifest = common.load(manifest_path)
    control.verify_manifest(manifest, os.environ.get('PETFLOW_DESTROY_RUN_ID'))
    journal = common.load(control.evidence_directory() / (manifest['runId'] + '-maintenance.json'))
    common.require(journal['status'] == 'deleting', 'storage cleanup was not authorized')
    state = common.download(manifest['kafka'])
    operator = common.get('deployment', 'strimzi-cluster-operator', 'kafka')
    common.require(not operator or (operator['spec']['replicas'] == 0 and
                   not operator.get('status', {}).get('replicas', 0)), 'Kafka Operator must be stopped')
    common.require(common.get('pod', state['podName'], 'kafka') is None, 'Kafka broker still exists')
    cluster = common.get('kafka', 'pet-subscription-kafka', 'kafka')
    common.require(not cluster or cluster['status']['clusterId'] == state['clusterId'],
                   'backup belongs to a different Kafka cluster')
    for volume in state['volumes']:
        volumes = common.aws('ec2', 'describe-volumes', '--filters',
                             'Name=volume-id,Values=' + volume['volumeId'])['Volumes']
        common.require(not volumes or (volumes[0]['State'] == 'available' and
                       not volumes[0].get('Attachments')), 'Kafka disk is still attached')
    backed_up = {t['metadata']['name'] for t in state['topics']}
    # Validate the whole set before changing any resource.
    for topic in topics:
        metadata = topic['metadata']
        common.require(metadata.get('deletionTimestamp') and metadata['name'] in backed_up and
                       metadata.get('labels', {}).get('strimzi.io/cluster') == 'pet-subscription-kafka',
                       'topic deletion is not covered by the verified backup')
    released = []
    for topic in topics:
        metadata = topic['metadata']
        before = metadata.get('finalizers', [])
        remaining = [f for f in before if f != 'strimzi.io/topic-operator']
        if remaining != before:
            common.kube('patch', 'kafkatopic', metadata['name'], '-n', 'kafka', '--type=merge',
                        '-p', json.dumps({'metadata': {'finalizers': remaining}}))
            released.append(metadata['name'])
    common.save(control.evidence_directory() / (manifest['runId'] + '-topic-cleanup.json'),
                {'runId': manifest['runId'], 'verifiedAt': common.utc(),
                 'backupVerified': True, 'brokerStopped': True, 'topicsReleased': released})
    return released


if __name__ == '__main__':
    try:
        common.identity()
        path = os.environ.get('PETFLOW_STATEFUL_BACKUP_MANIFEST')
        common.require(path, 'verified stateful backup manifest is required')
        released = release(path)
        print('[cleanup-k8s] Backed-up stopped Kafka topic finalizers released: {}'.format(', '.join(released)))
    except (RuntimeError, KeyError, OSError, ValueError) as error:
        print('[cleanup-k8s] ERROR: {}'.format(error), file=sys.stderr)
        sys.exit(1)

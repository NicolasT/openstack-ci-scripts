
import time

import heatclient.client
import keystoneclient.auth.identity.v2
import keystoneclient.session

from heatclient.common import template_utils


def client_session(auth_url, tenant, username, password, region=None):
    """
    Setup a keystone authenticated heat client session.

    :param auth_url: keystone authentication endpoint (v2)
    :type auth_url: string
    :param tenant: tenant name for authentication
    :type tenant: string
    :param username: user name for authentication
    :type username: string
    :param password: password to authenticate with
    :type password: string
    :param region: region to obtain heat client for (optional)
    :string region: string
    :return: :py:class:`heatclient.client.Client`
    """
    auth = keystoneclient.auth.identity.v2.Password(
        auth_url=auth_url,
        tenant_name=tenant,
        username=username,
        password=password,
    )

    keystone_session = keystoneclient.session.Session(auth=auth)
    heat_endpoint = keystone_session.get_endpoint(
        service_type='orchestration',
        interface='publicURL',
        region_name=region,
    )

    return heatclient.client.Client(
        version=1,
        endpoint=heat_endpoint,
        session=keystone_session,
    )


def deploy(name, template_file, heat_client, **kwargs):
    """
    Deploy infrastructure by heat.

    :param name: heat stack name
    :type name: string
    :param template_file: heat template to deploy
    :type template_file: string
    :param heat_client: heat client
    :type heat_client: :py:class:`heatclient.client.Client`
    :param kwargs: template parameters
    :type kwargs: keyword arguments
    :return: deployed stack
    """
    tpl_files, template = template_utils.get_template_contents(template_file)
    api_response = heat_client.stacks.create(
        stack_name=name,
        template=template,
        files=tpl_files,
        parameters=kwargs,
    )

    stack_id = api_response['stack']['id']

    # Wait for deployment to complete.
    retries = 60
    for retry in range(retries):
        time.sleep(5)
        stack = heat_client.stacks.get(stack_id)
        if stack.status == 'COMPLETE':
            break
    else:
        raise Exception(
            "Deployment of infrastructure failed. "
            "Stack id: '{0:s}' / {1:s}".format(stack_id, stack.status)
        )
    return stack

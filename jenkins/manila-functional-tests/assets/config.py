# ringsh configuration
default_config = {
    'accessor': None,
    'auth': {
        'user': '%(mgmtuser)s',
        'password': '%(mgmtpass)s',
    },
    'brs2': None,
    'dsup': { 'url': 'http://%(supervisor_host)s:3080' },
    'key': { 'class1translate': '0' },
    'node': %(node)s,
    'supervisor': { 'url': 'https://%(supervisor_host)s:2443' },
    'supv2': { 'url': 'http://%(supervisor_host)s:12345' },
}

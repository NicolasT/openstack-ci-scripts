{
    "dewpoint": {
        "protocols": [
            { "": "cdmi" }
        ],
        "storage": "sofs",
        "log_onerror": 0,
        "log_level": "info",
        "log_id": "dewpoint",
        "log_facility": "local5",
        "debug_mask": "NONE",
        "input_stream_block_size": 131072,
        "output_stream_block_size": 131072
    },
    "sofs": {
        "command": ["sofs", "-c", "/etc/dewpoint-sofs.js", "-T", "3", "-n", "dewpoint" ],
        "enable_fuse": true,
        "enterprise_number": 37489
    },
    "cdmi": {
        "plugins": ["scality_extensions"],
        "default_version": "1.0.1",
        "value_transfer_maxsize": 1048576
    },
    "fcgx": {
        "bind_addr": "",
        "port": 1039,
        "backlog": 1024,
        "n_responders": 32
    }
}


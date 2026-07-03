DOCUMENTATION = """
name: openstack_secret
author: TEDISC infra
short_description: Fetch a secret payload from OpenStack Barbican.
description:
  - Look up one or more secrets in OpenStack Barbican by exact name and return
    their payloads. Authenticates via openstacksdk, which honours the same
    conventions as the C(openstack) CLI (C(clouds.yaml), C(OS_*) environment
    variables, or an explicit C(cloud) name).
options:
  _terms:
    description: Names of the secrets to fetch (exact match).
    required: true
    type: list
    elements: str
  cloud:
    description:
      - Name of the entry in C(clouds.yaml) to authenticate against. If unset,
        falls back to the C(OS_CLOUD) environment variable, and then to
        openstacksdk's default resolution of C(OS_*) variables.
    type: str
requirements:
  - openstacksdk
  - python-barbicanclient
"""

EXAMPLES = """
- name: Load a Barbican secret into a variable
  ansible.builtin.set_fact:
    caddy_api_key: "{{ lookup('openstack_secret', 'caddy_api_key') }}"

- name: Explicit cloud entry from clouds.yaml
  ansible.builtin.set_fact:
    caddy_api_key: "{{ lookup('openstack_secret', 'caddy_api_key', cloud='openstack') }}"
"""

RETURN = """
_raw:
  description: The secret payload(s), one per input term, in the same order.
  type: list
  elements: str
"""

import os

from ansible.errors import AnsibleError, AnsibleLookupError
from ansible.plugins.lookup import LookupBase

try:
    import openstack
    from barbicanclient import client as barbican_client

    HAS_DEPS = True
    IMPORT_ERROR = None
except ImportError as exc:
    HAS_DEPS = False
    IMPORT_ERROR = exc


class LookupModule(LookupBase):
    def run(self, terms, variables=None, **kwargs):
        if not HAS_DEPS:
            raise AnsibleError(
                "openstack_secret lookup requires openstacksdk and "
                "python-barbicanclient (import failed: %s)" % IMPORT_ERROR
            )

        cloud = kwargs.get("cloud") or os.environ.get("OS_CLOUD")
        try:
            conn = openstack.connect(cloud=cloud) if cloud else openstack.connect()
        except Exception as exc:
            raise AnsibleError("openstack.connect() failed: %s" % exc)

        barbican = barbican_client.Client(session=conn.session)

        results = []
        for name in terms:
            # Barbican's list-by-name is a substring match; filter to exact.
            matches = [s for s in barbican.secrets.list(name=name) if s.name == name]
            if not matches:
                raise AnsibleLookupError(
                    "Barbican secret %r not found in project" % name
                )
            if len(matches) > 1:
                raise AnsibleLookupError(
                    "multiple Barbican secrets named %r found; refusing to "
                    "guess which one to use" % name
                )
            # Accessing `.payload` triggers a lazy GET of the secret payload.
            results.append(matches[0].payload)
        return results

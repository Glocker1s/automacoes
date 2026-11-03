"""Testes estáticos/templates sem exigir conexão com servidor AAP/Windows.
Executar na raiz do projeto: python tests/test_static.py
Requer PyYAML + Jinja2 (não necessários no EE além do Ansible).
"""
import csv
import io
from pathlib import Path
import json
import yaml
from jinja2 import Environment, FileSystemLoader

BASE = Path(__file__).resolve().parents[1]


def test_inventory():
    inv = yaml.safe_load((BASE / 'vars/environments.yml').read_text(encoding='utf-8'))
    envs = inv['csd_environments']
    assert {k: len(v) for k, v in envs.items()} == {'prd': 91, 'dr': 73, 'hml': 31, 'dev': 10}
    all_hosts = [name for names in envs.values() for name in names]
    assert len(all_hosts) == len(set(all_hosts)) == 205
    assert 'csd_host_metadata' not in inv
    assert 'AG-AC-VV-AP-10G' in envs['dr']
    print('OK inventory / 205 unique Windows hosts')


def test_yaml_json():
    for file in BASE.rglob('*.yml'):
        assert yaml.safe_load(file.read_text(encoding='utf8')) is not None
    survey = json.loads((BASE / 'survey_spec.json').read_text(encoding='utf8'))
    assert len(survey['spec']) == 2
    assert 'prd' in survey['spec'][0]['choices']
    publisher = (BASE/'tasks/55_publish_cifs.yml').read_text(encoding='utf-8')
    reporter = (BASE/'tasks/50_report.yml').read_text(encoding='utf-8')
    assert 'ansible.builtin.set_stats' in (BASE/'tasks/60_build_email_payload.yml').read_text(encoding='utf-8')
    assert '.cifs-pass' in publisher and 'mode: "0600"' in publisher
    assert 'smbclient' in publisher and '-U' in publisher and '%$(cat' in publisher
    assert 'smbclient -A' not in publisher
    config = (BASE/'vars/config.yml').read_text(encoding='utf-8')
    assert 'csd_cifs_username' not in config and 'csd_cifs_password' not in config
    assert 'csd_host_metadata' not in (BASE/'vars/environments.yml').read_text(encoding='utf-8')
    assert 'tutihofix' in (BASE/'vars/config.yml').read_text(encoding='utf-8')
    assert 'producao' in (BASE/'vars/config.yml').read_text(encoding='utf-8')
    for required in ('send_mail_subject','send_mail_body','send_mail_attachments',
                     'send_mail_cifs_remote_files','send_mail_cifs','send_mail_cifs_path',
                     'send_mail_cifs_address','cifs_workgroup'):
        assert required in (BASE/'tasks/60_build_email_payload.yml').read_text(encoding='utf-8')
    assert 'community.general.mail' not in reporter
    assert 'community.general.mail' not in publisher
    print('OK YAML, survey JSON and CIFS/set_stats workflow contract')


def test_reports():
    match = {
        'host': 'APP-HML-01', 'file': 'D:\\A;pp\\co"nfig.json', 'line': 18,
        'content': '=HYPERLINK("x");origem=SQL;senha=***CONTEUDO_SENSIVEL_OCULTADO***',
        'database_type': 'SQLSERVER', 'destination': 'SQL-HML-01',
        'database': 'APLICACAO', 'port': '1433',
    }
    host = {
        'host': 'APP-HML-01', 'environment': 'hml',
        'status': 'OK', 'files_scanned': 33, 'matches_count': 1, 'errors_count': 0,
        'elapsed_seconds': 7.2, 'results': [match],
    }
    ctx = {
        'csd_all_matches': [match], 'csd_reports': [host],
        'csd_total_hosts': 1, 'csd_total_files': 33, 'csd_total_errors': 0,
        'csd_ok_hosts': 1, 'csd_partial_hosts': 0, 'csd_error_hosts': 0,
        'csd_report_top_matches': 15, 'csd_timestamp': '20261029_120000',
        'hostvars': {'localhost': {'csd_requested_environment': 'hml'}},
        'csd_aap_base_url': '',
    }
    engine = Environment(loader=FileSystemLoader(BASE / 'templates'), autoescape=False)
    rendered_csv = engine.get_template('connections.csv.j2').render(**ctx)
    rows = list(csv.reader(io.StringIO(rendered_csv.lstrip('\ufeff')), delimiter=';', quotechar='"'))
    assert rendered_csv.startswith('\ufeff')
    assert rows[0] == ['Servidor', 'Arquivo', 'Linha', 'Conteudo']
    assert len(rows) == 2 and len(rows[1]) == 4
    assert rows[1][1] == match['file']
    assert rows[1][-1].startswith("'=HYPERLINK")
    assert rows[1][-1].count(';') == 2
    rendered_html = engine.get_template('report.html.j2').render(**ctx)
    assert 'Servidor / Aplicação' not in rendered_html
    assert 'APP-HML-01' in rendered_html
    assert 'SQL-HML-01' in rendered_html
    assert 'Tempo' in rendered_html
    print('OK CSV compatible, BOM, quote/semicolon protection, formula protection and HTML escaping')


if __name__ == '__main__':
    test_inventory()
    test_yaml_json()
    test_reports()
    print('ALL STATIC TESTS PASS')

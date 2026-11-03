"""Validação estática da massa de testes LAB sem WinRM, Ansible ou PowerShell."""
from pathlib import Path
import re
import yaml

BASE = Path(__file__).resolve().parents[1]


def main():
    lab_env = yaml.safe_load((BASE / 'vars/lab_environments.yml').read_text())
    assert {k: len(v) for k, v in lab_env['csd_environments'].items()} == {
        'prd': 1, 'dr': 1, 'hml': 1, 'dev': 1
    }
    hosts = [name for names in lab_env['csd_environments'].values() for name in names]
    assert len(set(hosts)) == 4
    assert 'csd_host_metadata' not in lab_env
    assert all(h.startswith('PREENCHER_') for h in hosts)

    cfg = yaml.safe_load((BASE / 'vars/lab_config.yml').read_text())
    assert cfg['csd_scan_scope'] == 'custom'
    assert cfg['csd_custom_roots'] == ['C:\\CSD-LAB']
    assert cfg['csd_publish_email_payload']
    assert cfg['csd_cifs_label'] == 'tutihofix'

    taskscan = yaml.safe_load((BASE / 'tasks/20_scan.yml').read_text())
    script = taskscan[2]['block'][0]['ansible.windows.win_powershell']['script']
    pat = next(x for x in script.splitlines() if x.strip().startswith('$signalRegex = ')).strip()
    regex = re.compile(pat.split(' = ', 1)[1][1:-1].replace("''", "'"))

    seed = yaml.safe_load((BASE / 'lab_prepare.yml').read_text())[1]['tasks'][1]['ansible.windows.win_powershell']['script']
    occurrences = {}
    current = None
    for line in seed.splitlines():
        found = re.search(r"\$files\['([^']+)'\] = @\(", line)
        if found:
            current = found.group(1)
            occurrences[current] = 0
            continue
        if current is None:
            continue
        if line.strip() == ')':
            current = None
            continue
        text = line.strip()
        if not (text.startswith("'") and text.endswith("'")):
            continue
        text = text[1:-1]
        if text.lstrip().startswith(('#', '//', '<!--', '*', ';')):
            continue
        if regex.search(text):
            occurrences[current] += 1

    excluded = {k for k in occurrences if k.startswith(('logs\\', 'backup\\'))
                or '.sample.' in k or k.endswith('.txt')}
    assert len(occurrences) == 12
    assert len(occurrences) - len(excluded) == 8
    assert sum(v for k, v in occurrences.items() if k not in excluded) == cfg['csd_lab_expected_matches'] == 9
    print('OK LAB: 4 host aliases, isolated path, 12 physical files, 8 eligible, 9 matches/VM')


if __name__ == '__main__':
    main()

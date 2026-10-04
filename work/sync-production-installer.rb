#!/usr/bin/env ruby
# Rebuild the standalone installer's embedded runtime from the reviewed sources.

root = File.expand_path('..', __dir__)
installer_path = File.join(root, 'outputs', 'install-openrct2-manager.sh')
manager_path = File.join(root, 'production', 'openrct2-manager.py')
helper_path = File.join(root, 'production', 'manager-helper.template.js')
backup_path = File.join(root, 'production', 'openrct2-backup')
verify_path = File.join(root, 'production', 'openrct2-verify-backup.py')
restore_path = File.join(root, 'production', 'openrct2-restore-backup')
https_path = File.join(root, 'production', 'openrct2-manager-enable-https')

installer = File.read(installer_path)
manager = File.read(manager_path).rstrip
helper = File.read(helper_path).rstrip
backup = File.read(backup_path).lines.drop(1).join.rstrip
verify = File.read(verify_path).lines.drop(1).join.rstrip
restore = File.read(restore_path).lines.drop(1).join.rstrip
https = File.read(https_path).lines.drop(1).join.rstrip

backup_start = "cat > /usr/local/sbin/openrct2-backup <<'BACKUP'\n"
backup_body = installer.index(backup_start) or abort('backup start marker not found')
backup_body += backup_start.length
backup_end = installer.index("\nBACKUP\n", backup_body) or abort('backup end marker not found')
installer = installer[0...backup_body] + backup + installer[backup_end..]

installer = installer.gsub(%r{cat > /usr/local/sbin/openrct2-verify-backup <<'VERIFY'\n.*?\nVERIFY\nchmod 0755 /usr/local/sbin/openrct2-verify-backup\n*}m, '')
verify_block = <<~SHELL
  cat > /usr/local/sbin/openrct2-verify-backup <<'VERIFY'
  #{verify}
  VERIFY
  chmod 0755 /usr/local/sbin/openrct2-verify-backup

SHELL
backup_anchor = "chmod 0755 /usr/local/sbin/openrct2-backup\n"
backup_anchor_at = installer.index(backup_anchor) or abort('backup install anchor not found')
backup_anchor_after = backup_anchor_at + backup_anchor.length
installer = installer[0...backup_anchor_after] + verify_block + installer[backup_anchor_after..]

installer = installer.gsub(%r{cat > /usr/local/sbin/openrct2-restore-backup <<'RESTORE'
.*?
RESTORE
chmod 0755 /usr/local/sbin/openrct2-restore-backup
*
}m, '')
restore_block = <<~SHELL
  cat > /usr/local/sbin/openrct2-restore-backup <<'RESTORE'
  #{restore}
  RESTORE
  chmod 0755 /usr/local/sbin/openrct2-restore-backup

SHELL
verify_anchor = "chmod 0755 /usr/local/sbin/openrct2-verify-backup\n"
verify_anchor_at = installer.index(verify_anchor) or abort('verify install anchor not found')
verify_anchor_after = verify_anchor_at + verify_anchor.length
installer = installer[0...verify_anchor_after] + restore_block + installer[verify_anchor_after..]

installer = installer.gsub(%r{cat > /usr/local/sbin/openrct2-manager-enable-https <<'HTTPSHELPER'\n.*?\nHTTPSHELPER\nchmod 0755 /usr/local/sbin/openrct2-manager-enable-https\n*}m, '')
https_block = <<~SHELL
  cat > /usr/local/sbin/openrct2-manager-enable-https <<'HTTPSHELPER'
  #{https}
  HTTPSHELPER
  chmod 0755 /usr/local/sbin/openrct2-manager-enable-https

SHELL
restore_anchor = "chmod 0755 /usr/local/sbin/openrct2-restore-backup\n"
restore_anchor_at = installer.index(restore_anchor) or abort('restore install anchor not found')
restore_anchor_after = restore_anchor_at + restore_anchor.length
installer = installer[0...restore_anchor_after] + https_block + installer[restore_anchor_after..]

start_marker = "cat > /usr/local/lib/openrct2-manager.py <<'PYAPP'\n"
end_marker = "\nPYAPP\n"
start = installer.index(start_marker) or abort('manager start marker not found')
body_start = start + start_marker.length
body_end = installer.index(end_marker, body_start) or abort('manager end marker not found')
installer = installer[0...body_start] + manager + installer[body_end..]

helper_block = <<~SHELL
  cat > /usr/local/share/openrct2-manager/manager-helper.template.js <<'JSTEMPLATE'
  #{helper}
  JSTEMPLATE
  chmod 0644 /usr/local/share/openrct2-manager/manager-helper.template.js

SHELL

# Remove previously generated helper blocks so repeated builds remain byte-stable.
installer = installer.gsub(%r{cat > /usr/local/share/openrct2-manager/manager-helper\.template\.js <<'JSTEMPLATE'\n.*?\nJSTEMPLATE\nchmod 0644 /usr/local/share/openrct2-manager/manager-helper\.template\.js\n\n}m, '')

anchor = "chmod 0755 /usr/local/lib/openrct2-manager.py\n"
anchor_at = installer.index(anchor) or abort('install anchor not found')
after_anchor = anchor_at + anchor.length
installer = installer[0...after_anchor] + helper_block + installer[after_anchor..]

File.write(installer_path, installer)
puts "Synced #{File.basename(manager_path)} and #{File.basename(helper_path)} into #{installer_path}"

/* Add the few narrow rules the VM needs to Android's compiled SELinux policy:
 * - graphics clients share memfd-backed buffers (each rule matches a denial seen in the guest log);
 * - the replacement Wi-Fi HAL keeps LD_LIBRARY_PATH (no secure exec from init);
 * - the vm-wifi service (image/guest_wifi.sh, root in the shell domain) sets up wlan0 on the
 *   network card. Only root processes there can use the capabilities, and
 *   the only one is that service (adb shell runs as the shell user, without them).
 * Does not change permissive domains, policy capabilities, MLS or constraints.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sepol/policydb/policydb.h>
#include <sepol/policydb/hashtab.h>
#include <sepol/policydb/avtab.h>

struct rule { const char *source, *target, *class, *perms[8]; };
static const struct rule rules[] = {
 {"platform_app", "hal_graphics_allocator_default", "memfd_file", {"read", "write", "map", "getattr"}},
 {"priv_app", "hal_graphics_allocator_default", "memfd_file", {"read", "write", "map", "getattr"}},
 {"priv_app_36", "hal_graphics_allocator_default", "memfd_file", {"read", "write", "map", "getattr"}},
 {"shell", "shell", "capability", {"net_admin"}},
 {"shell", "shell", "netlink_route_socket", {"create", "bind", "read", "write", "getattr", "setopt", "nlmsg_read", "nlmsg_write"}},
 // The generic Wi-Fi HAL (image/mica_wifi_port.py) runs with its own libraries from
 // LD_LIBRARY_PATH, which a secure exec (AT_SECURE) would drop
 {"init", "hal_wifi_default", "process", {"noatsecure"}},
 // ... and manages wlan0 over route netlink (the Qualcomm HAL it replaces never needed to)
 {"hal_wifi_default", "hal_wifi_default", "netlink_route_socket", {"create", "bind", "read", "write", "getattr", "setopt", "nlmsg_read", "nlmsg_write"}},
};

int main(int argc, char **argv) {
 if (argc != 3) return 2;
 policydb_t p; policy_file_t f; policydb_init(&p); policy_file_init(&f);
 f.type = PF_USE_STDIO; f.fp = fopen(argv[1], "rb"); if (!f.fp) return 3;
 if (policydb_read(&p, &f, 0)) return 4; fclose(f.fp);
 for (unsigned r = 0; r < sizeof rules / sizeof rules[0]; r++) {
  const struct rule *x = &rules[r];
  type_datum_t *source = hashtab_search(p.p_types.table, x->source), *target = hashtab_search(p.p_types.table, x->target);
  class_datum_t *c = hashtab_search(p.p_classes.table, x->class);
  if (!source || !target || !c) { fprintf(stderr, "missing %s %s %s\n", x->source, x->target, x->class); return 5; }
  unsigned bits = 0;
  for (unsigned i = 0; i < 8 && x->perms[i]; i++) {
   perm_datum_t *v = hashtab_search(c->permissions.table, x->perms[i]);
   if (!v && c->comdatum) v = hashtab_search(c->comdatum->permissions.table, x->perms[i]);
   if (!v || !v->s.value || v->s.value > 32) { fprintf(stderr, "missing permission %s:%s\n", x->class, x->perms[i]); return 6; }
   bits |= 1U << (v->s.value - 1);
  }
  avtab_key_t key = {.source_type = source->s.value, .target_type = target->s.value, .target_class = c->s.value, .specified = AVTAB_ALLOWED};
  avtab_datum_t *old = avtab_search(&p.te_avtab, &key);
  printf("allow %s %s:%s; prior_bits=%08x added_bits=%08x\n", x->source, x->target, x->class, old ? old->data : 0, bits & ~(old ? old->data : 0));
  if (old) old->data |= bits;
  else { avtab_datum_t val = {.data = bits}; if (avtab_insert(&p.te_avtab, &key, &val)) return 8; }
 }
 f.fp = fopen(argv[2], "wb"); if (!f.fp) return 9;
 if (policydb_write(&p, &f) || fclose(f.fp)) return 10; policydb_destroy(&p); return 0;
}

#include <dlfcn.h>
#include <libgen.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
// Load a QEMU library from this binary's own folder, never from anywhere the environment names.
// VM_QEMU_LIBRARY may pick one of the builds there by file name (the gfxstream build, or a copy
// set to another refresh rate, see run_vm.py), but not a path.
int main(int argc,char **argv,char **envp){
 char exe[PATH_MAX],real[PATH_MAX],path[PATH_MAX];uint32_t size=sizeof exe;
 if(_NSGetExecutablePath(exe,&size)||!realpath(exe,real))return 1;
 const char *name=getenv("VM_QEMU_LIBRARY");
 if(!name||!*name)name="qemu-aarch64-softmmu";
 if(strchr(name,'/')||strstr(name,"..")||(strncmp(name,"qemu-aarch64-softmmu",20)&&strncmp(name,"qemu-gfx-aarch64-softmmu",24))){
  fprintf(stderr,"VM_QEMU_LIBRARY must name a QEMU build next to the launcher\n");return 1;}
 if(snprintf(path,sizeof path,"%s/%s",dirname(real),name)>=(int)sizeof path)return 1;
 void *lib=dlopen(path,RTLD_LOCAL|RTLD_LAZY);
 if(!lib){fprintf(stderr,"%s\n",dlerror());return 1;}
 void (*init)(int,char**,char**)=dlsym(lib,"qemu_init");
 void (*loop)(void)=dlsym(lib,"qemu_main_loop");
 void (*cleanup)(void)=dlsym(lib,"qemu_cleanup");
 if(!init||!loop||!cleanup)return 2;
 init(argc,argv,envp);loop();cleanup();return 0;
}

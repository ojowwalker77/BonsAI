#include <stdio.h>
#include <unistd.h>

int main(int argc, char **argv) {
  if (argc < 2) {
    fputs("BonsAIAgentLauncher: missing executable\n", stderr);
    return 64;
  }

  // Become the leader of a fresh process group before exec. Every tool process spawned by the
  // agent inherits this group, allowing BonsAI to stop the complete turn without touching itself.
  if (setpgid(0, 0) != 0) {
    perror("BonsAIAgentLauncher: setpgid");
    return 71;
  }

  execv(argv[1], &argv[1]);
  perror("BonsAIAgentLauncher: execv");
  return 127;
}

struct Ops { void (*invoke)(void); };
void pointer_save(void) {}
void pointer_other(void) {}
static struct Ops ops = { pointer_save };
void pointer_run(void) { ops.invoke(); }

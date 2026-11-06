#ifndef TB_LOCAL_LOG_H
#define TB_LOCAL_LOG_H

/* Mirror stderr to ~/Library/Logs/TargetBridge/receiver-local.log.
 * Safe to call more than once. A missing home directory leaves stderr alone. */
void tb_local_log_start(void);

#endif

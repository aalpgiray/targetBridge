#ifndef TB_APPNAP_H
#define TB_APPNAP_H

/* Keep the render loop running when the receiver is not the front app.
 * Does not block idle system sleep. Safe to call more than once. */
void tb_appnap_hold_awake(void);

#endif

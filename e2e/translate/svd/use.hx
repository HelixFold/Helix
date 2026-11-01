// Uses what `helix translate-svd` made of demo.svd, the way firmware does; tests/run.sh builds it for a Cortex-M4.

import { GPIOA, GPIOB, TIMER, UART0, Interrupt, enableInterrupt } from "./demo.expected";

export extern "C" function IRQ28_Handler(): void {
    TIMER.CHA_CTRL.clear(.EN);
}

export function main(): void {
    GPIOA.MODER.modify(.MODER3, 1);
    GPIOB.ODR.set(.OD1);
    if (GPIOA.ODR.get(.OD0) == 1) GPIOA.LCKR.write(0x1_0000);
    TIMER.CNT.write(TIMER.CNT.get(.type_) + 1);
    TIMER.CCR1.modify(.CCR, 500);
    UART0.DATA.write(65);
    enableInterrupt(Interrupt.TIMER);
}

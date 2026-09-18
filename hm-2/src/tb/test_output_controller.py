import os

from enum import Enum
from itertools import product
from pathlib import Path

import cocotb
from cocotb.triggers import Timer
from cocotb_tools.runner import get_runner

os.environ['COCOTB_ANSI_OUTPUT'] = '1'

class State(Enum):
    IDLE = 0b00
    BUSY = 0b01
    FAULT = 0b10
    UNLOCK = 0b11
    RESET = 0b100

expected_output_states = { #[busy, fault, unlock]
    State.IDLE: [0, 0, 0],
    State.BUSY: [1, 0, 0],
    State.FAULT: [0, 1, 0],
    State.UNLOCK: [0, 0, 1],
    State.RESET: [1, 1, 0],
}

class OutputControllerTest:

    def __init__(self, dut) -> None:
        self.dut = dut
        self.state = dut.state
        self.busy = dut.busy
        self.fault = dut.fault
        self.unlock = dut.unlock

    async def set_state(self, state: int):
        self.dut._log.info(f"Setting state to {state}")
        self.state.value = state
        await Timer(1, "ns")

@cocotb.test()
async def test_all_state_transitions(dut):
    tester = OutputControllerTest(dut)
    transitions = list(product(State, State))
    for from_state, to_state in transitions:
        await OutputControllerTest(dut).set_state(from_state.value)
        await OutputControllerTest(dut).set_state(to_state.value)
        expected_state = expected_output_states[to_state]
        assert [tester.busy.value, tester.fault.value, tester.unlock.value] == expected_state, f"Expected output states {expected_state}, got {[tester.busy.value, tester.fault.value, tester.unlock.value]}"
        tester.dut._log.info(f"Transitioned from {from_state.name} to {to_state.name}")

@cocotb.test()
async def test_outputs_off_in_undef_state(dut):
    tester = OutputControllerTest(dut)
    undef_states = [i for i in range (0, 7) if i not in [s.value for s in State]]
    for undef_state in undef_states:
        await tester.set_state(undef_state)
        expected_output_state = [0, 0, 0]
        assert [tester.busy.value, tester.fault.value, tester.unlock.value] == expected_output_state, f"Expected output states {expected_output_state}, got {[tester.busy.value, tester.fault.value, tester.unlock.value]}"
    tester.dut._log.info("Tested all undefined states (outputs off)")

def test_output_controller():
    sim = os.getenv("SIM", "icarus")
    proj_path = Path(__file__).resolve().parent.parent
    sources = [proj_path / "rtl" / "output_controller.v"]
    runner = get_runner(sim)
    runner.build(
        sources = sources,
        hdl_toplevel = "output_controller",
        always = True,
        waves = True,
        timescale=("1ns", "1ps")
    )
    runner.test(hdl_toplevel="output_controller", test_module="test_output_controller", waves=True)

def test_output_controller_netlist():
    sim = os.getenv("SIM", "icarus")
    proj_path = Path(__file__).resolve().parent.parent
    sources = [proj_path / "ll_configs" / "runs" / "output_controller" / "06-yosys-synthesis" / "output_controller.nl.v"]
    sources.append(proj_path / "technology"/ "stdcells.v")
    runner = get_runner(sim)
    runner.build(
        sources = sources,
        hdl_toplevel = "output_controller",
        always = True,
        waves = True,
        timescale=("1ns", "1ps")
    )
    runner.test(hdl_toplevel="output_controller", test_module="test_output_controller", waves=True)

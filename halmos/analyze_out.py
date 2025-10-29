import json
import sys


def decode_selector(selector_bytes):
    """Decode common function selectors"""
    selectors = {
        "0xbb4fc585": "openMakerPosition",
        "0x57ce6547": "openTakerPosition",
        "0xecf6eca0": "addMargin",
        "0xd91f66f8": "closePosition",
        "0x6bb00ff2": "increaseCardinalityCap",
    }
    return selectors.get(selector_bytes[:10], selector_bytes)


def format_value(value, solidity_type, var_name=""):
    """Format a value based on its Solidity type"""
    if solidity_type == "address":
        return f"0x{value:040x}"
    elif solidity_type == "bytes32":
        return f"0x{value:064x}"
    elif solidity_type == "bytes4":
        selector_hex = f"0x{value:08x}"
        if var_name == "selector":
            decoded = decode_selector(selector_hex)
            return f"{selector_hex} ({decoded})"
        return selector_hex
    elif solidity_type == "bool":
        return "true" if value == 1 else "false"
    elif "uint" in solidity_type:
        return str(value)
    elif "int" in solidity_type:
        bit_size = int(solidity_type.replace("int", ""))
        if value >= 2 ** (bit_size - 1):
            value = value - 2**bit_size
        return str(value)
    else:
        return str(value)


def analyze_halmos_output(file_path):
    with open(file_path, "r") as f:
        data = json.load(f)

    print("Test Results Summary:\n" + "=" * 80)

    for contract, tests in data["test_results"].items():
        print(f"\nContract: {contract}\n")

        for test in tests:
            print(
                f"Test: {test['name']}\n"
                f"Exit Code: {test['exitcode']}\n"
                f"Num Counterexamples: {test['num_models']}\n"
                f"Num Paths: {test['num_paths']}\n" # number of paths: [total, success, blocked]
                f"Time: {test['time']}s\n" # time: [total, paths, models]
                f"Bounded Loops: {test['num_bounded_loops']}\n" # number of incomplete loops
            )

            if test["num_models"] > 0 and "models" in test:
                print("Counterexamples:\n" + "-" * 78)

                for i, model in enumerate(test["models"], 1):
                    if not model.get("is_valid", False):
                        continue

                    print(f"\n[{i}]")

                    params = {}
                    state = {}
                    other = {}

                    for var_name, var_data in model["model"].items():
                        display_name = var_data.get("variable_name", var_name)
                        solidity_type = var_data.get("solidity_type", "unknown")
                        value = var_data.get("value", 0)
                        formatted_value = format_value(
                            value, solidity_type, display_name
                        )

                        if display_name.startswith("p_"):
                            params[display_name[2:]] = (formatted_value, solidity_type)
                        elif display_name.startswith("block."):
                            state[display_name] = (formatted_value, solidity_type)
                        elif any(
                            x in display_name
                            for x in ["maker", "taker", "creator", "liquidator"]
                        ):
                            if "maker." in display_name or "taker." in display_name:
                                params[display_name] = (formatted_value, solidity_type)
                            else:
                                state[display_name] = (formatted_value, solidity_type)
                        else:
                            other[display_name] = (formatted_value, solidity_type)

                    if params:
                        print("\nParameters:")
                        for name, (value, sol_type) in sorted(params.items()):
                            print(f"{name} = {value} ({sol_type})")

                    if state:
                        print("\nState:")
                        for name, (value, sol_type) in sorted(state.items()):
                            print(f"{name} = {value} ({sol_type})")

                    if other:
                        print("\nOther:")
                        for name, (value, sol_type) in sorted(other.items()):
                            print(f"{name} = {value} ({sol_type})")

                print("\n" + "-" * 78)

    print("\n" + "=" * 80)
    print(f"Overall Exit Code: {data['exitcode']}")


if __name__ == "__main__":
    file_path = sys.argv[1] if len(sys.argv) > 1 else "halmos/out/halmos_test.json"
    print(f"Analyzing Halmos output from {file_path}\n")
    analyze_halmos_output(file_path)

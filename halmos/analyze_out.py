import json
import sys


def analyze_halmos_output(file_path):
    with open(file_path, "r") as f:
        data = json.load(f)
    print("Test Results Summary:")
    print("=" * 60)
    for contract, tests in data["test_results"].items():
        print(f"Contract: {contract}")
        for test in tests:
            print(f"  Test: {test['name']}")
            print(f"    Exit Code: {test['exitcode']}")
            print(f"    Num Models (Counterexamples): {test['num_models']}")
            print(f"    Num Paths: {test['num_paths']}")
            print(f"    Time: {test['time'][0]:.2f}s")
            print(f"    Bounded Loops: {test['num_bounded_loops']}")
    print("=" * 60)
    print(f'Overall Exit Code: {data["exitcode"]}')


if __name__ == "__main__":
    if len(sys.argv) > 1:
        file_path = sys.argv[1]
    else:
        file_path = "halmos/out/halmos_test.json"
    print(f"Analyzing Halmos output from {file_path}")
    analyze_halmos_output(file_path)

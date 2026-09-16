#!/usr/bin/env python3
"""Generates a main.swift that runs every `func test...` in every XCTestCase
subclass under the given directory. Only needed by test-without-swiftpm.sh;
`swift test` discovers tests by itself."""
import os, re, sys

directory = sys.argv[1]
class_re = re.compile(r'^\s*(?:public\s+|final\s+|open\s+)*class\s+(\w+)\s*:\s*XCTestCase\b')
func_re = re.compile(r'^\s*(?:public\s+|private\s+|internal\s+)?func\s+(test\w*)\s*\(\s*\)\s*(throws\b)?')

suites = []
for name in sorted(os.listdir(directory)):
    if not name.endswith('.swift'):
        continue
    current = None
    for line in open(os.path.join(directory, name)):
        m = class_re.match(line)
        if m:
            current = (m.group(1), [])
            suites.append(current)
            continue
        m = func_re.match(line)
        if m and current is not None:
            current[1].append((m.group(1), bool(m.group(2))))

out = ['import Foundation', 'import XCTest', '']
out.append('var executed = 0')
out.append('var failedTests = 0')
out.append('let recorder = TestFailureRecorder.shared')
out.append('')
for class_name, methods in suites:
    for method, throwing in methods:
        call = 'try instance.%s()' % method if throwing else 'instance.%s()' % method
        out.append('do {')
        out.append('    let instance = %s()' % class_name)
        out.append('    recorder.currentTest = "%s.%s"' % (class_name, method))
        out.append('    let before = recorder.failures.count')
        out.append('    instance.setUp()')
        if throwing:
            out.append('    do { %s } catch { recorder.record("threw \\(error)", #file, #line) }' % call)
        else:
            out.append('    %s' % call)
        out.append('    instance.tearDown()')
        out.append('    executed += 1')
        out.append('    if recorder.failures.count > before { failedTests += 1 }')
        out.append('}')
out.append('')
out.append('for failure in recorder.failures { print("FAIL  " + failure) }')
out.append('print("")')
out.append('if failedTests == 0 {')
out.append('    print("PASSED  \\(executed) tests, \\(recorder.failures.count) failures")')
out.append('} else {')
out.append('    print("FAILED  \\(executed) tests, \\(failedTests) failing, \\(recorder.failures.count) assertions")')
out.append('    exit(1)')
out.append('}')
print('\n'.join(out))

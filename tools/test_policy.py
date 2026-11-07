import tempfile, unittest
from pathlib import Path
from policy import decide

class PolicyTests(unittest.TestCase):
    def test_branches_and_both_lists(self):
        with tempfile.TemporaryDirectory() as d:
            a,b = Path(d)/'login',Path(d)/'nonlogin'
            for path in (a,b):
                path.write_text('aa:bb:cc:dd:ee:ff\n')
                for visible,expected in ((True,False),(False,True)):
                    self.assertEqual(decide('AA:BB:CC:DD:EE:FF', visible,[a,b])['core_branch_allows'],expected)
                path.unlink()
            for visible,expected in ((True,True),(False,False)):
                self.assertEqual(decide('aa:bb:cc:dd:ee:ff',visible,[a,b])['core_branch_allows'],expected)

if __name__ == '__main__': unittest.main()

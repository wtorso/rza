module rez3asm;

fn void test_nav_utf16_bmp_boundaries() @test {
	test::eq(nav_utf16_to_byte("A€B", 0)!!, 0);
	test::eq(nav_utf16_to_byte("A€B", 1)!!, 1);
	test::eq(nav_utf16_to_byte("A€B", 2)!!, 4);
	test::eq(nav_utf16_to_byte("A€B", 3)!!, 5);
	test::eq(@catch(nav_utf16_to_byte("A€B", 4)), NOT_FOUND);
	test::eq(nav_byte_to_utf16("A€B", 4)!!, 2);
	test::eq(nav_byte_to_utf16("A€B", 5)!!, 3);
	test::eq(@catch(nav_byte_to_utf16("A€B", 2)), NOT_FOUND);
}

fn void test_nav_utf16_non_bmp_boundaries() @test {
	test::eq(nav_utf16_to_byte("😀x", 0)!!, 0);
	test::eq(nav_utf16_to_byte("😀x", 2)!!, 4);
	test::eq(nav_utf16_to_byte("😀x", 3)!!, 5);
	test::eq(@catch(nav_utf16_to_byte("😀x", 1)), NOT_FOUND);
	test::eq(nav_byte_to_utf16("😀x", 4)!!, 2);
	test::eq(nav_byte_to_utf16("😀x", 5)!!, 3);
	test::eq(@catch(nav_byte_to_utf16("😀x", 2)), NOT_FOUND);
}

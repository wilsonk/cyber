type S:
    a float

var o = S{a=123}
o.a = {_}

--cytest: error
--CompileError: Expected type `float`, got `List[dyn]`.
--
--main:5:7:
--o.a = {_}
--      ^
--
if has("rootpw")
then (.rootpw = "********")
else .
end
|
walk(
  if type == "object" and has("password")
  then (.password = "********")
  else .
  end
)

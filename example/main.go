package main

import (
	"os/user"

	"github.com/kr/pretty"
)

func main() {
	u, err := user.Current()
	if err != nil {
		panic(err)
	}
	pretty.Println(u.Username)
}

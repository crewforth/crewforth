package main

import (
	"fmt"
	"os"

	"example.com/gosvc/internal/store"
	"github.com/gin-gonic/gin"
	redis "github.com/redis/go-redis/v9"
	"github.com/missing/dep"
)

func main() {
	_ = os.Getenv("GO_DEFINED")
	_ = os.Getenv("GO_MISSING")
	r := gin.Default()
	r.GET("/health", nil)
	v1 := r.Group("/v1")
	v1.POST("/jobs/:id", nil)
	fmt.Println(store.X, redis.Nil, dep.Y)
}

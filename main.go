package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"runtime"
	"runtime/pprof"

	gosdkstorage "cloud.google.com/go/storage"

	"google.golang.org/api/googleapi"
	"google.golang.org/api/storage/v1"
)

type gcpStorage struct {
	api *storage.Service
	sdk *gosdkstorage.Client

	useSDK     bool
	bucketName string
	chunkSize  int
}

func (gcs *gcpStorage) upload(ctx context.Context, name string, r io.Reader) (string, error) {
	if gcs.useSDK {
		return gcs.uploadUsingSDK(ctx, name, r)
	}
	return gcs.uploadUsingAPI(ctx, name, r)
}

func (gcs *gcpStorage) uploadUsingAPI(_ context.Context, name string, r io.Reader) (string, error) {
	obj, err := gcs.api.Objects.Insert(gcs.bucketName, &storage.Object{
		Name: name,
	}).Media(r, googleapi.ChunkSize(gcs.chunkSize)).Do()
	if err != nil {
		return "", err
	}

	return obj.Name, nil
}

func (gcs *gcpStorage) uploadUsingSDK(ctx context.Context, name string, r io.Reader) (string, error) {
	w := gcs.sdk.Bucket(gcs.bucketName).Object(name).NewWriter(ctx)
	defer w.Close()

	if _, err := io.Copy(w, r); err != nil {
		return "", err
	}

	return w.Name, nil
}

func main() {
	pf, err := os.CreateTemp("/tmp", "memprofile")
	if err != nil {
		log.Fatalf("create temp: %v", err)
	}
	defer func() {
		pprof.Lookup("allocs").WriteTo(pf, 0)
		log.Println("profile:", pf.Name())
	}()

	bucketName := flag.String("b", "vasil-averyanau-test", "bucket name")
	fileToUpload := flag.String("f", "./1.txt", "path to flag to upload")
	count := flag.Int("n", 1, "numbers of times to upload")
	useSDK := flag.Bool("sdk", false, "use sdk, otherwise api client is used")
	chunkSize := flag.Int("chunk-size", googleapi.DefaultUploadChunkSize, "chunk size for uploads (0 disables chunking)")

	flag.Parse()

	ctx := context.Background()
	apiClient, err := storage.NewService(ctx)
	if err != nil {
		log.Fatalf("api storage.NewClient: %v", err)
	}

	sdkClient, err := gosdkstorage.NewClient(ctx)
	if err != nil {
		log.Fatalf("sdk storage.NewClient: %v", err)
	}

	svc := &gcpStorage{
		api: apiClient,
		sdk: sdkClient,

		useSDK:     *useSDK,
		bucketName: *bucketName,
		chunkSize:  *chunkSize,
	}

	printMemStats("initial")

	for i := range *count {
		fd, err := os.Open(*fileToUpload)
		if err != nil {
			log.Fatalf("os.Open: %v", err)
		}

		name := fmt.Sprintf("%s-%d.txt",
			filepath.Clean(fd.Name()),
			i,
		)

		objName, err := svc.upload(ctx, name, fd)
		if err != nil {
			log.Fatalf("upload: %v", err)
		}

		fd.Close()
		log.Printf("[%d/%d] success: %s", i+1, *count, objName)
		runtime.GC()
		printMemStats(fmt.Sprintf("after upload %d/%d", i+1, *count))
	}

	runtime.GC()
	printMemStats("final (after GC)")
}

func printMemStats(label string) {
	var mStats runtime.MemStats
	runtime.ReadMemStats(&mStats)

	log.Printf("[mem %s] sys=%.2fMB total_alloc=%.2fMB heap_alloc=%.2fMB heap_inuse=%.2fMB heap_objects=%d",
		label,
		toMB(mStats.Sys),
		toMB(mStats.TotalAlloc),
		toMB(mStats.HeapAlloc),
		toMB(mStats.HeapInuse),
		mStats.HeapObjects,
	)
}

func toMB(b uint64) float64 {
	return float64(b) / 1024.0 / 1024.0
}

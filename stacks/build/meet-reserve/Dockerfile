FROM golang:1.24-alpine@sha256:8bee1901f1e530bfb4a7850aa7a479d17ae3a18beb6e09064ed54cfd245b7191 AS build
WORKDIR /src
COPY go.mod main.go store.go peers.go index.html logo.png favicon.png ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /meet-reserve .

FROM gcr.io/distroless/static-debian12:nonroot@sha256:afa5c872c891853ca7fcf1f12c3edb23f7eeef36189728842dd51042ff57f7ab
COPY --from=build /meet-reserve /meet-reserve
USER nonroot
EXPOSE 8095
ENTRYPOINT ["/meet-reserve"]
